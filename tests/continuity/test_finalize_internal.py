"""Internal TestFlight finalization contracts; no live API or credentials."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import { executeInternal, INTERNAL_GROUP } from INTERNAL_URL;
import { Journal, APP, BUNDLE, VERSION, DEFAULT_CONTENT, MARKETING_URL, PRIVACY_URL, checkPublicURLs } from PUBLIC_URL;
import { readFileSync } from 'node:fs';
const input = JSON.parse(readFileSync(0,'utf8'));
const buildID='11111111-2222-3333-4444-555555555555';
const state={
 app:{id:APP,attributes:{bundleId:BUNDLE}},
 build:{id:buildID,attributes:{version:'1003.1',processingState:'VALID',buildAudienceType:'APP_STORE_ELIGIBLE',expired:false,expirationDate:'2099-01-01T00:00:00Z',usesNonExemptEncryption:false}},
 version:{id:'version-id',attributes:{version:VERSION,platform:'IOS'}},
 detail:{id:'detail-id',attributes:{autoNotifyEnabled:true,internalBuildState:'READY_FOR_BETA_TESTING'}},
 groups:[{id:INTERNAL_GROUP,attributes:{name:'Existing internal group',isInternalGroup:true,hasAccessToAllBuilds:false}}],
 appLocales:[{id:'app-locale',attributes:{locale:'en-US',description:'Old chemistry app',feedbackEmail:'private-feedback@example.invalid'}}],
 buildLocales:[], groupBuilds:[{type:'builds',id:'older-build'}], submission:null,
};
const calls=[];
const clone=data=>({data:structuredClone(data)});
let loseAssociation=input.scenario==='lost-association';
async function api(path,method='GET',body) {
 calls.push({path,method,body});
 if(method==='GET') {
  if(path===`apps/${APP}` || path===`builds/${buildID}/app`) return clone(state.app);
  if(path===`builds/${buildID}`) return clone(state.build);
  if(path.endsWith('/preReleaseVersion')) return clone(state.version);
  if(path.includes('/betaGroups?')) return clone(state.groups);
  if(path.endsWith('/buildBetaDetail')) return clone(state.detail);
  if(path.endsWith('/betaAppReviewSubmission')) return clone(state.submission);
  if(path.includes('/betaAppLocalizations?')) return clone(state.appLocales);
  if(path.includes('/betaBuildLocalizations?')) return clone(state.buildLocales);
  if(path.includes('/relationships/builds?')) return clone(state.groupBuilds);
 }
 if(method==='PATCH') {
  const row=[state.build,state.detail,...state.appLocales,...state.buildLocales].find(row=>row.id===body.data.id);
  if(!row) throw new Error('Unknown patch');
  Object.assign(row.attributes,body.data.attributes); return clone(row);
 }
 if(method==='POST' && path==='betaBuildLocalizations') {
  const row={...body.data,id:'build-locale'};state.buildLocales.push(row);return clone(row);
 }
 if(method==='POST' && path===`betaGroups/${INTERNAL_GROUP}/relationships/builds`) {
  if(loseAssociation){loseAssociation=false;throw new Error('Uncertain write response');}
  state.groupBuilds.push(...body.data);
  if(input.scenario!=='pending')state.detail.attributes.internalBuildState='IN_BETA_TESTING';
  return {data:null};
 }
 throw new Error('Forbidden or unexpected endpoint');
}
if(input.scenario==='wrong-group') state.groups[0].attributes.isInternalGroup=false;
if(input.scenario==='missing-group') state.groups=[];
if(input.scenario==='wrong-version') state.version.attributes.version='0.2.0';
if(input.scenario==='wrong-bundle') state.app.attributes.bundleId='different.bundle';
if(input.scenario==='invalid-build') state.build.attributes.processingState='PROCESSING';
if(input.scenario==='internal-only') state.build.attributes.buildAudienceType='INTERNAL_ONLY';
if(input.scenario==='expired') state.build.attributes.expired=true;
if(input.reviewState) state.submission={id:'submission-id',attributes:{betaReviewState:input.reviewState}};
if(input.metadataPrepared) {
 Object.assign(state.appLocales[0].attributes,{description:DEFAULT_CONTENT.description,marketingUrl:MARKETING_URL,privacyPolicyUrl:PRIVACY_URL});
 state.buildLocales=[{id:'build-locale',attributes:{locale:'en-US',whatsNew:DEFAULT_CONTENT.whatsNew}}];
 state.detail.attributes.autoNotifyEnabled=false;
}
if(input.metadataDrift==='description') state.appLocales[0].attributes.description='Different reviewed description';
if(input.metadataDrift==='whatsNew') state.buildLocales[0].attributes.whatsNew='Different reviewed test instructions';
if(input.metadataDrift==='missing-locale') state.buildLocales=[];
if(input.scenario.startsWith('encryption-')) state.build.attributes.usesNonExemptEncryption=null;
if(input.scenario==='encryption-conflict') state.build.attributes.usesNonExemptEncryption=true;
let receipt=null;
if(['encryption-good','encryption-wrong-build','encryption-missing-field','encryption-conflict'].includes(input.scenario)) {
 receipt={bundle:BUNDLE,version:VERSION,build:'1003.1',identity_verified:true,usesNonExemptEncryption:false};
 if(input.scenario==='encryption-wrong-build')receipt.build='old-build';
 if(input.scenario==='encryption-missing-field')delete receipt.usesNonExemptEncryption;
}
const journal=new Journal(input.directory);
const options={api,journal,buildID,apply:!!input.apply,compiledIdentity:receipt,urlCheck:async()=>true};
if(input.scenario==='url-failure')options.urlCheck=()=>checkPublicURLs(async()=>({status:404,body:{cancel:async()=>{}}}));
if(input.reviewDuringURLs) options.urlCheck=async()=>{state.submission={id:'submission-id',attributes:{betaReviewState:'IN_REVIEW'}};return true;};
const reports=[];
try {
 reports.push(await executeInternal(options));
 if(['repeat','lost-association'].includes(input.scenario))reports.push(await executeInternal(options));
 console.log(JSON.stringify({reports,state,calls,journal:journal.data}));
} finally {journal.close();}
'''.replace('INTERNAL_URL', json.dumps((ROOT / 'scripts/release/finalize-internal.mjs').as_uri())).replace('PUBLIC_URL', json.dumps((ROOT / 'scripts/release/public-beta.mjs').as_uri()))


@unittest.skipUnless(shutil.which("node"), "Node required")
class InternalFinalizationTests(unittest.TestCase):
    def scenario(self, scenario="default", apply=False, **options):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["node", "--input-type=module", "-e", HARNESS],
                                    input=json.dumps({"scenario": scenario, "apply": apply, "directory": directory, **options}),
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def writes(self, result):
        return [call for call in result["calls"] if call["method"] != "GET"]

    def test_default_is_read_only_and_needs_no_external_contact(self):
        result = self.scenario()
        self.assertEqual(result["reports"][-1]["state"], "PREFLIGHT_READY")
        self.assertFalse(result["reports"][-1]["external_review_contact_required"])
        self.assertEqual(self.writes(result), [])
        self.assertFalse(any("betaAppReviewDetail" in call["path"] for call in result["calls"]))
        self.assertTrue(any("betaAppReviewSubmission" in call["path"] for call in result["calls"]))

    def test_pending_or_approved_review_blocks_metadata_rewrites_before_any_mutation(self):
        for review in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
            for drift in ("description", "whatsNew", "missing-locale"):
                with self.subTest(review=review, drift=drift):
                    result = self.scenario(apply=True, reviewState=review,
                                           metadataPrepared=True, metadataDrift=drift)
                    self.assertEqual(result["reports"][-1]["state"], "BLOCKED_REVIEW")
                    self.assertEqual(self.writes(result), [])

    def test_identical_reviewed_metadata_allows_only_internal_association(self):
        for review in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
            with self.subTest(review=review):
                result = self.scenario(apply=True, reviewState=review, metadataPrepared=True)
                self.assertEqual(result["reports"][-1]["state"], "INTERNAL_BETA_AVAILABLE")
                self.assertEqual(result["reports"][-1]["external_review_state"], review)
                self.assertEqual([(call["method"], call["path"]) for call in self.writes(result)],
                                 [("POST", "betaGroups/5a93cfb4-bd7c-4c0c-acbd-ade02816d8c1/relationships/builds")])

    def test_review_starting_during_url_checks_is_rechecked_before_mutation(self):
        result = self.scenario(apply=True, reviewDuringURLs=True)
        self.assertEqual(result["reports"][-1]["state"], "BLOCKED_REVIEW")
        self.assertEqual(result["reports"][-1]["external_review_state"], "IN_REVIEW")
        self.assertEqual(self.writes(result), [])

    def test_exact_app_build_version_and_internal_group_guards(self):
        for scenario in ("wrong-group", "missing-group", "wrong-version", "wrong-bundle", "invalid-build", "internal-only", "expired"):
            with self.subTest(scenario=scenario):
                result = self.scenario(scenario, True)
                self.assertTrue(result["reports"][-1]["state"].startswith("BLOCKED_"))
                self.assertEqual(self.writes(result), [])

    def test_unset_encryption_requires_exact_explicit_compiled_evidence(self):
        for scenario in ("encryption-missing", "encryption-wrong-build", "encryption-missing-field"):
            with self.subTest(scenario=scenario):
                result = self.scenario(scenario, True)
                self.assertEqual(result["reports"][-1]["state"], "BLOCKED_ENCRYPTION_EVIDENCE")
                self.assertEqual(self.writes(result), [])

    def test_matching_compiled_receipt_allows_only_false_declaration(self):
        result = self.scenario("encryption-good", True)
        writes = self.writes(result)
        self.assertEqual(writes[0]["body"]["data"]["attributes"], {"usesNonExemptEncryption": False})
        self.assertEqual(result["reports"][-1]["state"], "INTERNAL_BETA_AVAILABLE")
        self.assertTrue(result["reports"][-1]["compiled_identity_receipt_verified"])

    def test_true_apple_declaration_conflict_is_never_overwritten(self):
        result = self.scenario("encryption-conflict", True)
        self.assertEqual(result["reports"][-1]["state"], "BLOCKED_ENCRYPTION_CONFLICT")
        self.assertEqual(self.writes(result), [])

    def test_metadata_and_exact_association_are_read_back(self):
        result = self.scenario(apply=True)
        report = result["reports"][-1]
        self.assertEqual(report["state"], "INTERNAL_BETA_AVAILABLE")
        self.assertTrue(report["exact_build_associated"])
        self.assertEqual(report["internal_build_state"], "IN_BETA_TESTING")
        self.assertFalse(report["auto_notify_enabled"])
        self.assertFalse(report["tester_installation_verified"])
        attributes = result["state"]["buildLocales"][0]["attributes"]
        self.assertIn("whatsNew", attributes)
        self.assertIn("release before touchdown", attributes["whatsNew"])
        self.assertNotIn("description", attributes)
        self.assertEqual(len(result["state"]["groups"]), 1)
        self.assertEqual(result["state"]["groupBuilds"][0]["id"], "older-build")

    def test_repeat_is_idempotent_with_no_second_mutation(self):
        result = self.scenario("repeat", True)
        self.assertEqual([row["state"] for row in result["reports"]], ["INTERNAL_BETA_AVAILABLE", "INTERNAL_BETA_AVAILABLE"])
        self.assertEqual(result["reports"][-1]["mutations"], [])
        self.assertEqual(sum(call["method"] == "POST" and call["path"].endswith('/relationships/builds') for call in result["calls"]), 1)

    def test_observed_membership_does_not_invent_activation(self):
        result = self.scenario("pending", True)
        report = result["reports"][-1]
        self.assertEqual(report["state"], "INTERNAL_ACTIVATION_PENDING")
        self.assertTrue(report["exact_build_associated"])
        self.assertFalse(report["internal_beta_available"])
        self.assertFalse(report["tester_installation_verified"])

    def test_public_metadata_must_be_available_before_writes(self):
        result = self.scenario("url-failure", True)
        self.assertEqual(result["reports"][-1]["state"], "BLOCKED_METADATA")
        self.assertEqual(self.writes(result), [])

    def test_uncertain_association_is_not_blindly_reposted(self):
        result = self.scenario("lost-association", True)
        self.assertEqual(result["reports"][-1]["state"], "BLOCKED_RECONCILE")
        self.assertEqual(sum(call["method"] == "POST" and call["path"].endswith('/relationships/builds') for call in result["calls"]), 1)

    def test_no_email_output_upload_group_creation_or_invitation(self):
        result = self.scenario(apply=True)
        self.assertNotIn("private-feedback@example.invalid", json.dumps(result["reports"]))
        forbidden = ('upload', 'notification', 'betatesters', 'betaappreviewdetail')
        self.assertFalse(any(any(word in call["path"].lower() for word in forbidden) for call in result["calls"]))
        self.assertFalse(any('betaappreview' in call['path'].lower() for call in self.writes(result)))
        self.assertFalse(any(call["method"] == 'POST' and call["path"] == 'betaGroups' for call in result["calls"]))


if __name__ == "__main__":
    unittest.main()
