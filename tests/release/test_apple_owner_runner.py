import copy
import hashlib
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('apple_owner', HERE.parents[1] / 'scripts/apple-owner-runner.py')
owner = importlib.util.module_from_spec(spec); spec.loader.exec_module(owner)


class FakeApple:
    def __init__(self):
        self.group = {'data': {'id': owner.GROUP, 'attributes': {'name': 'Owner', 'isInternalGroup': True, 'publicLinkEnabled': False},
            'relationships': {'app': {'data': {'id': owner.APP}}, 'betaTesters': {'data': [{'id': 'synthetic-owner'}]}}},
            'included': [{'id': 'synthetic-owner', 'type': 'betaTesters', 'attributes': {'email': "owner@example.invalid"}}]}
        self.members = {'data': copy.deepcopy(self.group['included']), 'links': {}, 'meta': {'paging': {'total': 1}}}
        self.builds = {'data': [{'id': 'synthetic-build', 'attributes': {'version': '21.1', 'buildAudienceType': 'INTERNAL_ONLY',
            'expired': False, 'processingState': 'VALID'}}], 'links': {}}
        self.linked = []; self.posts = []

    def request(self, path, body=None):
        if path.startswith('apps/'):
            return copy.deepcopy(self.builds)
        if '?include=' in path:
            return copy.deepcopy(self.group)
        if '/betaTesters?' in path:
            return copy.deepcopy(self.members)
        if body:
            self.posts.append((path, copy.deepcopy(body))); self.linked.extend(body['data']); return {}
        return {'data': copy.deepcopy(self.linked), 'links': {}}


class AppleOwnerTests(unittest.TestCase):
    def setUp(self):
        self.owner_hash = patch.object(owner, 'OWNER_SHA256', hashlib.sha256(b'owner@example.invalid').hexdigest())
        self.owner_hash.start()
        self.addCleanup(self.owner_hash.stop)

    def test_actual_openssl_signature_round_trips_as_es256_without_exposing_key(self):
        import shutil
        executable = shutil.which('openssl') or r'C:\Program Files\Git\usr\bin\openssl.exe'
        pem = subprocess.run([executable, 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256'],
            capture_output=True, check=True, timeout=15).stdout.decode()
        original = subprocess.run
        def openssl(command, **kwargs):
            self.assertEqual(command[0], 'openssl')
            self.assertIn('env', kwargs, 'JWT signing must receive an explicit minimal environment')
            self.assertFalse(any('SYNTHETIC-PRIVATE-MARKER' in value for value in kwargs['env'].values()))
            result = original([executable, *command[1:]], **kwargs)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            return result
        with tempfile.TemporaryDirectory(dir=HERE) as directory, patch.object(owner.subprocess, 'run', side_effect=openssl), \
             patch.dict(os.environ, {'APPLE_CERTIFICATE_BASE64': 'SYNTHETIC-PRIVATE-MARKER'}):
            result = owner.token({'apiKeyID': 'SYNTHETIC', 'issuerID': 'synthetic', 'apiPrivateKey': pem}, directory)
            head, payload, signature = result.split('.')
            decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
            raw = decode(signature)
            self.assertEqual(len(raw), 64)
            integers = []
            for value in (raw[:32], raw[32:]):
                value = value.lstrip(b'\0')
                if value[0] >= 128: value = b'\0' + value
                integers.append(b'\x02' + bytes([len(value)]) + value)
            body = b''.join(integers)
            signature_path = Path(directory) / 'signature.der'
            signature_path.write_bytes(b'\x30' + bytes([len(body)]) + body)
            public = original([executable, 'pkey', '-pubout'], input=pem.encode(), capture_output=True, check=True).stdout
            public_path = Path(directory) / 'public.pem'; public_path.write_bytes(public)
            verified = original([executable, 'dgst', '-sha256', '-verify', str(public_path), '-signature', str(signature_path)],
                input=(head + '.' + payload).encode(), capture_output=True, timeout=15)
            self.assertEqual(verified.returncode, 0, 'Actual OpenSSL signature verification must pass')
        claims = json.loads(decode(payload))
        self.assertEqual(claims['iss'], 'synthetic')
        self.assertEqual(claims['exp'] - claims['iat'], 600)
        self.assertNotIn('PRIVATE KEY', result)

    def test_unused_build_number_requires_complete_list_and_exact_existing_owner(self):
        apple = FakeApple()
        owner.before_upload(apple, '22.1')
        for value in ('21.1', '20.1'):
            with self.assertRaises(ValueError): owner.before_upload(apple, value)
        apple.builds['links']['next'] = 'synthetic-next-page'
        with self.assertRaises(ValueError): owner.before_upload(apple, '22.1')

    def test_wrong_group_app_members_or_public_link_prevent_assignment(self):
        mutations = [lambda a: a.group['data']['attributes'].update(publicLinkEnabled=True),
            lambda a: a.group['data']['attributes'].update(isInternalGroup=False),
            lambda a: a.group['data']['relationships']['app']['data'].update(id='wrong'),
            lambda a: a.group['included'].append(copy.deepcopy(a.group['included'][0])),
            lambda a: a.group['included'][0]['attributes'].update(email='other@example.invalid')]
        for mutation in mutations:
            apple = FakeApple(); mutation(apple)
            with self.assertRaises(ValueError): owner.finish(apple, '21.1', seconds=0)
            self.assertEqual(apple.posts, [])

    def test_partial_paginated_or_inconsistent_membership_never_assigns(self):
        changes = [lambda a: a.members['links'].update(next='synthetic-next'),
            lambda a: a.members['meta']['paging'].update(total=2),
            lambda a: a.members['data'].append({'id': 'other', 'type': 'betaTesters', 'attributes': {'email': 'other@example.invalid'}}),
            lambda a: a.group['data']['relationships']['betaTesters']['data'].append({'id': 'other'})]
        for change in changes:
            apple = FakeApple(); change(apple)
            with self.assertRaises(ValueError): owner.finish(apple, '21.1', seconds=0)
            self.assertEqual(apple.posts, [])

    def test_valid_internal_build_assigns_only_existing_group_once_and_reads_back(self):
        apple = FakeApple()
        result = owner.finish(apple, '21.1', seconds=0)
        self.assertEqual(result, dict(version='21.1', state='VALID', audience='INTERNAL_ONLY', assigned=True, onlyApprovedOwner=True))
        self.assertEqual(apple.posts, [(f'betaGroups/{owner.GROUP}/relationships/builds', {'data': [{'type': 'builds', 'id': 'synthetic-build'}]})])
        owner.finish(apple, '21.1', seconds=0)
        self.assertEqual(len(apple.posts), 1)

    def test_processing_missing_external_expired_or_failed_build_never_assigns(self):
        for change in ({'processingState': 'PROCESSING'}, {'processingState': 'FAILED'},
                       {'buildAudienceType': 'APP_STORE'}, {'expired': True}):
            apple = FakeApple(); apple.builds['data'][0]['attributes'].update(change)
            if change == {'processingState': 'PROCESSING'}:
                self.assertFalse(owner.finish(apple, '21.1', seconds=0)['assigned'])
            else:
                with self.assertRaises(ValueError): owner.finish(apple, '21.1', seconds=0)
            self.assertEqual(apple.posts, [])
        apple = FakeApple(); apple.builds['data'] = []
        self.assertEqual(owner.finish(apple, '21.1', seconds=0)['state'], 'NOT_RECEIVED')
        self.assertEqual(apple.posts, [])


if __name__ == '__main__': unittest.main()
