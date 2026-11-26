"""Shared TestFlight metadata survives public/internal helper interoperation.

The real JavaScript exports run against a strict in-memory API and a temporary,
on-disk operator journal. No Apple endpoint, credential, or notification is used.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import { execute, Journal, APP, BUNDLE, VERSION, GROUP_NAME, DEFAULT_CONTENT } from PUBLIC_URL;
import { executeInternal, INTERNAL_GROUP } from INTERNAL_URL;
import { readFileSync } from 'node:fs';

// Any accidental network fallback must fail the scenario, never reach Apple.
globalThis.fetch = async () => { throw new Error('Network is forbidden in this fixture'); };
const input = JSON.parse(readFileSync(0, 'utf8'));
const buildID = '11111111-2222-3333-4444-555555555555';
const sourceSHA = 'a'.repeat(40);
const evidence = { sourceSHA,
  compiledIdentity: { bundle: BUNDLE, version: VERSION, build: '1003.1', identity_verified: true, usesNonExemptEncryption: false },
  releaseReceipt: { commit: sourceSHA, app_store_app_id: APP, bundle_identifier: BUNDLE, version: VERSION,
    build: '1003.1', signature_verified: true, upload_accepted: true, ipa_sha256: 'b'.repeat(64) },
  processingReceipt: { app_id: APP, version: VERSION, build: '1003.1', apple_build_id: buildID, apple_processing: 'VALID' },
};
const publicGroupID = 'public-group';
const contact = {
  firstName: 'Fixture', lastName: 'Reviewer',
  email: 'reviewer@example.invalid', phone: '+12025550123',
};
const customContent = {
  description: 'Reviewed custom description: ride the current with a single touch and keep a clean landing streak.',
  whatsNew: 'Reviewed custom test plan: check controlled dives, release before touchdown, and resume a charged run safely.',
  reviewNotes: 'Reviewed custom notes: play the three courses as a guest, then inspect retry, local results and sharing.',
};
// Omitting content in the default scenario exercises both actual default values.
const contentOptions = input.custom ? { content: customContent } : {};
const expectedContent = input.custom ? customContent : DEFAULT_CONTENT;
const state = {
  app: { type: 'apps', id: APP, attributes: { bundleId: BUNDLE } },
  build: { type: 'builds', id: buildID, attributes: {
    version: '1003.1', processingState: 'VALID', buildAudienceType: 'APP_STORE_ELIGIBLE',
    expired: false, expirationDate: '2099-01-01T00:00:00Z', usesNonExemptEncryption: false,
  } },
  version: { type: 'preReleaseVersions', id: 'version-id', attributes: { version: VERSION, platform: 'IOS' } },
  detail: { type: 'buildBetaDetails', id: 'detail-id', attributes: {
    autoNotifyEnabled: true, internalBuildState: 'READY_FOR_BETA_TESTING',
    externalBuildState: 'READY_FOR_BETA_SUBMISSION',
  } },
  review: { type: 'betaAppReviewDetails', id: APP, attributes: {} },
  appLocales: [{ type: 'betaAppLocalizations', id: 'app-locale', attributes: {
    locale: 'en-US', description: 'Old app description', feedbackEmail: 'feedback@example.invalid',
  } }],
  buildLocales: [],
  groups: [{ type: 'betaGroups', id: INTERNAL_GROUP, attributes: {
    name: 'Existing internal group', isInternalGroup: true, hasAccessToAllBuilds: false,
  } }],
  // Distinct relationships matter: public staging must not satisfy internal membership.
  groupBuilds: { [INTERNAL_GROUP]: [{ type: 'builds', id: 'older-internal-build' }] },
  submission: null,
};
const calls = [];
let phase;
const clone = data => ({ data: structuredClone(data) });

async function api(path, method = 'GET', body) {
  calls.push({ phase, path, method, body: body ? structuredClone(body) : null });
  if (method === 'GET') {
    if (path === `apps/${APP}` || path === `builds/${buildID}/app`) return clone(state.app);
    if (path === `builds/${buildID}`) return clone(state.build);
    if (path === `builds/${buildID}/preReleaseVersion`) return clone(state.version);
    if (path === `builds/${buildID}/buildBetaDetail`) return clone(state.detail);
    if (path === `builds/${buildID}/betaAppReviewSubmission`) return clone(state.submission);
    if (path === `apps/${APP}/betaAppReviewDetail`) return clone(state.review);
    if (path === `apps/${APP}/betaAppLocalizations?limit=200`) return clone(state.appLocales);
    if (path === `builds/${buildID}/betaBuildLocalizations?limit=200`) return clone(state.buildLocales);
    if (path === `apps/${APP}/betaGroups?limit=200`) return clone(state.groups);
    const relationship = /^betaGroups\/([^/]+)\/relationships\/builds\?limit=200$/.exec(path);
    if (relationship && Object.hasOwn(state.groupBuilds, relationship[1])) {
      return clone(state.groupBuilds[relationship[1]]);
    }
  }
  if (method === 'PATCH') {
    const row = [state.detail, state.review, ...state.appLocales, ...state.buildLocales, ...state.groups]
      .find(value => `${value.type}/${value.id}` === path);
    if (!row || body?.data?.type !== row.type || body.data.id !== row.id) {
      throw new Error('Unknown or mismatched fixture PATCH');
    }
    Object.assign(row.attributes, body.data.attributes);
    return clone(row);
  }
  if (method === 'POST' && path === 'betaGroups') {
    if (state.groups.some(row => row.id === publicGroupID)
        || body?.data?.type !== 'betaGroups' || body.data.attributes.name !== GROUP_NAME
        || body.data.attributes.isInternalGroup !== false
        || body.data.relationships.app.data.id !== APP) {
      throw new Error('Unexpected or duplicate public group creation');
    }
    const row = { ...structuredClone(body.data), id: publicGroupID };
    state.groups.push(row);
    state.groupBuilds[publicGroupID] = [];
    return clone(row);
  }
  if (method === 'POST' && path === 'betaBuildLocalizations') {
    if (state.buildLocales.length || body?.data?.type !== 'betaBuildLocalizations'
        || body.data.attributes.locale !== 'en-US'
        || body.data.relationships.build.data.type !== 'builds'
        || body.data.relationships.build.data.id !== buildID) {
      throw new Error('Unexpected or duplicate build localization creation');
    }
    const row = { ...structuredClone(body.data), id: 'build-locale' };
    state.buildLocales.push(row);
    return clone(row);
  }
  const association = /^betaGroups\/([^/]+)\/relationships\/builds$/.exec(path);
  if (method === 'POST' && association && Object.hasOwn(state.groupBuilds, association[1])) {
    if (!Array.isArray(body?.data) || body.data.length !== 1
        || body.data[0].type !== 'builds' || body.data[0].id !== buildID) {
      throw new Error('Unexpected build association payload');
    }
    const members = state.groupBuilds[association[1]];
    if (!members.some(row => row.id === buildID)) members.push(...structuredClone(body.data));
    if (association[1] === INTERNAL_GROUP) state.detail.attributes.internalBuildState = 'IN_BETA_TESTING';
    return { data: null }; // Apple relationship POST succeeds with HTTP 204.
  }
  // Includes review submissions, invitations, tester changes, and notification endpoints.
  throw new Error(`Forbidden fixture endpoint: ${method} ${path}`);
}

function metadata() {
  return {
    description: state.appLocales[0].attributes.description,
    whatsNew: state.buildLocales[0]?.attributes.whatsNew,
    reviewNotes: state.review.attributes.notes,
  };
}

async function withJournal(name, operation) {
  phase = name;
  const journal = new Journal(input.directory);
  try { return await operation(journal); }
  finally { journal.close(); }
}

const base = { api, buildID, ...evidence, urlCheck: async () => true, ...contentOptions };
const staged = await withJournal('public-stage', journal =>
  execute({ ...base, journal, contact, action: 'stage', apply: true }));
const afterStage = metadata();
if (input.reviewState) state.submission = { id: 'submission-id', attributes: { betaReviewState: input.reviewState } };
const internalContent = input.internalMismatch ? { content: { ...expectedContent,
  whatsNew: 'Different internal metadata must not replace the externally reviewed test instructions.' } } : {};
const finalized = await withJournal('internal-finalize', journal =>
  executeInternal({ ...base, ...internalContent, journal, apply: true }));
const afterInternal = metadata();
const preflight = await withJournal('public-submit-preflight', journal =>
  execute({ ...base, journal, action: 'submit', apply: false }));
const afterPreflight = metadata();

console.log(JSON.stringify({
  reports: [staged, finalized, preflight], calls,
  metadata: [afterStage, afterInternal, afterPreflight], expectedContent,
  groupBuilds: state.groupBuilds, groups: state.groups,
  buildID, internalGroupID: INTERNAL_GROUP, publicGroupID,
  autoNotifyEnabled: state.detail.attributes.autoNotifyEnabled,
  submission: state.submission,
}));
'''.replace(
    'PUBLIC_URL', json.dumps((ROOT / 'scripts/release/public-beta.mjs').as_uri())
).replace(
    'INTERNAL_URL', json.dumps((ROOT / 'scripts/release/finalize-internal.mjs').as_uri())
)


@unittest.skipUnless(shutil.which('node'), 'Node is required for helper integration tests')
class BetaHelperInteroperationTests(unittest.TestCase):
    def scenario(self, *, custom, **options):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ['node', '--input-type=module', '-e', HARNESS],
                input=json.dumps({'custom': custom, 'directory': directory, **options}),
                text=True, capture_output=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def assert_interoperates(self, result):
        self.assertEqual(
            [report['state'] for report in result['reports']],
            ['STAGED_PRIVATE', 'INTERNAL_BETA_AVAILABLE', 'PREFLIGHT_READY'],
        )
        for report in result['reports']:
            self.assertEqual(report['blockers'], [])
            self.assertTrue(report['metadata_staged'])
        self.assertTrue(result['reports'][1]['internal_beta_available'])
        self.assertEqual(result['reports'][2]['proposed_action'], 'submit')

        # Both helpers must retain the same reviewed app/build/review text verbatim.
        self.assertEqual(result['metadata'], [result['expectedContent']] * 3)
        internal_writes = [call for call in result['calls']
                           if call['phase'] == 'internal-finalize' and call['method'] != 'GET']
        self.assertEqual(
            [(call['method'], call['path']) for call in internal_writes],
            [('POST', f"betaGroups/{result['internalGroupID']}/relationships/builds")],
            'Internal finalization may associate the build but must not rewrite staged metadata',
        )
        self.assertFalse(any(
            call['phase'] == 'public-submit-preflight' and call['method'] != 'GET'
            for call in result['calls']
        ))
        self.assertEqual(sum(
            call['method'] == 'POST' and call['path'] == 'betaBuildLocalizations'
            for call in result['calls']
        ), 1)

        self.assertEqual(result['groupBuilds'][result['publicGroupID']],
                         [{'type': 'builds', 'id': result['buildID']}])
        self.assertEqual(result['groupBuilds'][result['internalGroupID']], [
            {'type': 'builds', 'id': 'older-internal-build'},
            {'type': 'builds', 'id': result['buildID']},
        ])
        self.assertEqual(len(result['groups']), 2)
        public_group = next(row for row in result['groups'] if row['id'] == result['publicGroupID'])
        self.assertFalse(public_group['attributes']['publicLinkEnabled'])
        self.assertFalse(result['autoNotifyEnabled'])
        self.assertIsNone(result['submission'])
        self.assertFalse(any(
            any(word in call['path'].lower() for word in ('notification', 'invitation', 'betatesters'))
            for call in result['calls']
        ))

    def test_default_content_survives_public_stage_internal_finalize_submit_preflight(self):
        self.assert_interoperates(self.scenario(custom=False))

    def test_reviewed_custom_content_survives_the_same_helper_sequence(self):
        result = self.scenario(custom=True)
        self.assertIn('Reviewed custom test plan', result['expectedContent']['whatsNew'])
        self.assert_interoperates(result)

    def test_review_in_progress_or_approved_survives_identical_internal_reconciliation(self):
        for review in ('IN_REVIEW', 'APPROVED'):
            with self.subTest(review=review):
                result = self.scenario(custom=True, reviewState=review)
                self.assertEqual([report['state'] for report in result['reports']],
                                 ['STAGED_PRIVATE', 'INTERNAL_BETA_AVAILABLE', 'PREFLIGHT_READY'])
                self.assertEqual(result['metadata'], [result['expectedContent']] * 3)
                internal_writes = [call for call in result['calls']
                                   if call['phase'] == 'internal-finalize' and call['method'] != 'GET']
                self.assertEqual([call['path'] for call in internal_writes],
                                 [f"betaGroups/{result['internalGroupID']}/relationships/builds"])

    def test_different_internal_content_cannot_invalidate_public_review_metadata(self):
        result = self.scenario(custom=True, reviewState='IN_REVIEW', internalMismatch=True)
        self.assertEqual([report['state'] for report in result['reports']],
                         ['STAGED_PRIVATE', 'BLOCKED_REVIEW', 'PREFLIGHT_READY'])
        self.assertEqual(result['metadata'], [result['expectedContent']] * 3)
        self.assertFalse(any(call['phase'] == 'internal-finalize' and call['method'] != 'GET'
                             for call in result['calls']))


if __name__ == '__main__':
    unittest.main()
