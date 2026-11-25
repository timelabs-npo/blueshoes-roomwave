"""Node helper contract tests use an in-memory Apple API, never live credentials."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / "scripts/release/public-beta.mjs"
HARNESS = r'''
import { execute, Journal, APP, BUNDLE, VERSION, GROUP_NAME, DEFAULT_CONTENT, checkPublicURLs } from HELPER_URL;
import { readFileSync } from 'node:fs';
const input = JSON.parse(readFileSync(0, 'utf8'));
const buildID = '11111111-2222-3333-4444-555555555555';
const contact = { firstName: 'PRIVATE_FIRST_SENTINEL', lastName: 'PRIVATE_LAST_SENTINEL', email: 'private-contact@example.invalid', phone: '+12025550123' };
const state = {
 app: { type:'apps', id:APP, attributes:{ bundleId:BUNDLE } },
 build: { type:'builds', id:buildID, attributes:{version:'1003.1',processingState:'VALID',buildAudienceType:'APP_STORE_ELIGIBLE',expired:false,expirationDate:'2099-01-01T00:00:00Z'} },
 version: { type:'preReleaseVersions', id:'version-id', attributes:{version:VERSION,platform:'IOS'} },
 detail: { type:'buildBetaDetails', id:'detail-id', attributes:{autoNotifyEnabled:true,externalBuildState:'READY_FOR_BETA_SUBMISSION'} },
 review: { type:'betaAppReviewDetails', id:APP, attributes:{} },
 appLocales:[{type:'betaAppLocalizations',id:'app-locale',attributes:{locale:'en-US',description:'Old chemistry description',feedbackEmail:'private-feedback@example.invalid'}}],
 buildLocales:[],
 groups:[{type:'betaGroups',id:'internal-group',attributes:{isInternalGroup:true,name:'Developers'}}],
 groupBuilds:[], submission:null,
};
const calls=[];
let failGroup = ['lost-create','lost-create-observed'].includes(input.scenario);
function clone(data) { return {data:structuredClone(data)}; }
async function api(path, method='GET', body) {
 calls.push({path,method,body});
 if(method==='GET') {
   if(path===`apps/${APP}` || path===`builds/${buildID}/app`) return clone(state.app);
   if(path===`builds/${buildID}`) return clone(state.build);
   if(path.endsWith('/preReleaseVersion')) return clone(state.version);
   if(path.endsWith('/buildBetaDetail')) return clone(state.detail);
   if(path.endsWith('/betaAppReviewSubmission')) return clone(state.submission);
   if(path.endsWith('/betaAppReviewDetail')) return clone(state.review);
   if(path.includes('/betaAppLocalizations?')) return clone(state.appLocales);
   if(path.includes('/betaBuildLocalizations?')) return clone(state.buildLocales);
   if(path.includes('/betaGroups?')) return clone(state.groups);
   if(path.includes('/relationships/builds?')) return clone(state.groupBuilds);
 }
 if(method==='PATCH') {
   const row=[state.detail,state.review,...state.appLocales,...state.buildLocales,...state.groups].find(row=>row.id===body.data.id);
   if(!row) throw new Error('Unknown fixture patch');
   Object.assign(row.attributes,body.data.attributes);
   if(body.data.type==='betaGroups' && body.data.attributes.publicLinkEnabled) row.attributes.publicLink='https://testflight.apple.com/join/Observed123';
   return clone(row);
 }
 if(method==='POST' && path==='betaGroups') {
   if(failGroup) {
     failGroup=false;
     if(input.scenario==='lost-create-observed') state.groups.push({...body.data,id:'public-group'});
     throw new Error('simulated lost response');
   }
   const row={...body.data,id:'public-group'}; state.groups.push(row); return clone(row);
 }
 if(method==='POST' && path==='betaBuildLocalizations') {
   const row={...body.data,id:'build-locale'}; state.buildLocales.push(row); return clone(row);
 }
 if(method==='POST' && path.includes('/relationships/builds')) {state.groupBuilds=body.data;return {data:null};}
 if(method==='POST' && path==='betaAppReviewSubmissions') {
   state.submission={type:'betaAppReviewSubmissions',id:'submission-id',attributes:{betaReviewState:'WAITING_FOR_REVIEW'}};
   state.detail.attributes.externalBuildState='WAITING_FOR_BETA_REVIEW';
   return clone(state.submission);
 }
 throw new Error('Unexpected fixture endpoint');
}
if(input.scenario==='wrong-bundle') state.app.attributes.bundleId='different.bundle';
if(input.scenario==='wrong-version') state.version.attributes.version='0.2.0';
if(input.scenario==='internal-only') state.build.attributes.buildAudienceType='INTERNAL_ONLY';
if(input.scenario==='expired') state.build.attributes.expired=true;
if(input.scenario==='extra-locale') state.appLocales.push({id:'fr',attributes:{locale:'fr-FR',description:'Old chemistry'}});
if(input.scenario==='other-build') {
 state.groups.push({id:'public-group',attributes:{name:GROUP_NAME,isInternalGroup:false,hasAccessToAllBuilds:false}});
 state.groupBuilds=[{type:'builds',id:'different-build'}];
}
const journal=new Journal(input.directory);
const base={api,journal,buildID,contact:input.scenario==='missing-contact'?null:contact,urlCheck:async()=>true};
const results=[];
try {
 if(input.scenario==='url-failure') base.urlCheck=()=>checkPublicURLs(async()=>({status:404,body:{cancel:async()=>{}}}));
 if(['repeat-stage','submit','approved','unapproved','rejected','lost-create','lost-create-observed'].includes(input.scenario)) {
   results.push(await execute({...base,action:'stage',apply:true}));
 }
 if(['repeat-stage','lost-create','lost-create-observed'].includes(input.scenario)) results.push(await execute({...base,action:'stage',apply:true}));
 else if(input.scenario==='submit') {
   results.push(await execute({...base,action:'submit',apply:true}));
   results.push(await execute({...base,action:'submit',apply:true}));
 } else if(['approved','unapproved','rejected'].includes(input.scenario)) {
   state.submission={id:'submission-id',type:'betaAppReviewSubmissions',attributes:{betaReviewState:input.scenario==='approved'?'APPROVED':input.scenario==='rejected'?'REJECTED':'WAITING_FOR_REVIEW'}};
   state.detail.attributes.externalBuildState=input.scenario==='approved'?'BETA_APPROVED':'WAITING_FOR_BETA_REVIEW';
   results.push(await execute({...base,action:input.scenario==='rejected'?'submit':'enable-public-link',apply:true}));
 } else if(!['repeat-stage','lost-create','lost-create-observed'].includes(input.scenario)) {
   results.push(await execute({...base,action:input.action||'preflight',apply:!!input.apply}));
 }
 console.log(JSON.stringify({results,calls,state,journal:journal.data}));
} finally {journal.close();}
'''.replace('HELPER_URL', json.dumps(HELPER.as_uri()))


@unittest.skipUnless(shutil.which("node"), "Node is required for public-beta helper tests")
class PublicBetaTests(unittest.TestCase):
    def scenario(self, scenario="default", **options):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["node", "--input-type=module", "-e", HARNESS],
                                    input=json.dumps({"scenario": scenario, "directory": directory, **options}),
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def writes(self, result):
        return [row for row in result["calls"] if row["method"] != "GET"]

    def test_default_and_stage_without_apply_are_read_only(self):
        for action in ("preflight", "stage"):
            result = self.scenario(action=action)
            self.assertEqual(result["results"][-1]["state"], "PREFLIGHT_READY")
            self.assertEqual(self.writes(result), [])

    def test_identity_and_eligibility_block_before_mutation(self):
        for scenario in ("wrong-bundle", "wrong-version", "internal-only", "expired", "other-build", "extra-locale"):
            with self.subTest(scenario=scenario):
                result = self.scenario(scenario, action="stage", apply=True)
                self.assertTrue(result["results"][-1]["state"].startswith("BLOCKED_"))
                self.assertEqual(self.writes(result), [])

    def test_contact_and_public_privacy_url_are_real_preconditions(self):
        for scenario, code in (("missing-contact", "BLOCKED_INPUT"), ("url-failure", "BLOCKED_METADATA")):
            result = self.scenario(scenario, action="stage", apply=True)
            self.assertEqual(result["results"][-1]["state"], code)
            self.assertEqual(self.writes(result), [])

    def test_stage_correct_whatsnew_and_disabled_capped_external_group(self):
        result = self.scenario(action="stage", apply=True)
        self.assertEqual(result["results"][-1]["state"], "STAGED_PRIVATE")
        group = result["state"]["groups"][-1]["attributes"]
        self.assertEqual(group["name"], "Roomwave Public Beta")
        self.assertEqual(group["publicLinkLimit"], 200)
        self.assertFalse(group["publicLinkEnabled"])
        self.assertFalse(group["isInternalGroup"])
        self.assertFalse(result["state"]["detail"]["attributes"]["autoNotifyEnabled"])
        localization = result["state"]["buildLocales"][0]["attributes"]
        self.assertIn("whatsNew", localization)
        self.assertNotIn("description", localization)
        self.assertEqual(result["state"]["groupBuilds"], [{"type":"builds", "id":"11111111-2222-3333-4444-555555555555"}])

    def test_repeated_stage_reuses_resources_and_has_no_writes(self):
        result = self.scenario("repeat-stage")
        self.assertEqual([row["state"] for row in result["results"]], ["STAGED_PRIVATE", "STAGED_PRIVATE"])
        self.assertEqual(result["results"][-1]["mutations"], [])
        self.assertEqual(sum(row["path"] == "betaGroups" and row["method"] == "POST" for row in result["calls"]), 1)

    def test_receipts_do_not_contain_private_contact_or_feedback(self):
        for options in ({}, {"action": "stage", "apply": True}):
            report = json.dumps(self.scenario(**options)["results"])
            for private in ("PRIVATE_FIRST_SENTINEL", "PRIVATE_LAST_SENTINEL", "private-contact@example.invalid", "private-feedback@example.invalid", "+12025550123"):
                self.assertNotIn(private, report)

    def test_submit_is_exact_and_preserves_submission_without_duplicate_post(self):
        result = self.scenario("submit")
        submissions = [row for row in self.writes(result) if row["path"] == "betaAppReviewSubmissions"]
        self.assertEqual(len(submissions), 1)
        self.assertEqual(submissions[0]["body"]["data"]["relationships"]["build"]["data"]["id"], "11111111-2222-3333-4444-555555555555")
        self.assertEqual(result["results"][-1]["review_submission_id"], "submission-id")
        self.assertEqual(result["results"][-1]["state"], "EXTERNAL_REVIEW_PENDING")
        self.assertFalse(result["state"]["groups"][-1]["attributes"]["publicLinkEnabled"])

    def test_unstaged_submit_preview_reports_blocker(self):
        result = self.scenario(action="submit")
        self.assertEqual(result["results"][-1]["state"], "BLOCKED_METADATA")
        self.assertEqual(self.writes(result), [])

    def test_public_link_requires_approved_exact_build(self):
        pending = self.scenario("unapproved")
        self.assertEqual(pending["results"][-1]["state"], "BLOCKED_REVIEW")
        self.assertFalse(pending["state"]["groups"][-1]["attributes"]["publicLinkEnabled"])
        approved = self.scenario("approved")
        report = approved["results"][-1]
        self.assertEqual(report["state"], "PUBLIC_LINK_ENABLED")
        self.assertEqual(report["public_url"], "https://testflight.apple.com/join/Observed123")
        self.assertFalse(report["external_testing_active"])
        self.assertFalse(report["tester_access_verified"])

    def test_rejected_submission_is_never_automatically_resubmitted(self):
        result = self.scenario("rejected")
        self.assertEqual(result["results"][-1]["state"], "BLOCKED_REVIEW")
        self.assertFalse(any(row["path"] == "betaAppReviewSubmissions" for row in self.writes(result)))

    def test_unknown_post_outcome_keeps_intent_and_blocks_duplicate_creation(self):
        result = self.scenario("lost-create")
        self.assertEqual(result["results"][-1]["state"], "BLOCKED_RECONCILE")
        self.assertEqual(sum(row["path"] == "betaGroups" and row["method"] == "POST" for row in result["calls"]), 1)
        self.assertEqual(result["journal"]["intents"]["group:6837899703:Roomwave Public Beta"]["state"], "INTENT_RECORDED")

    def test_lost_response_with_observed_group_reuses_exact_resource(self):
        result = self.scenario("lost-create-observed")
        self.assertEqual(result["results"][-1]["state"], "STAGED_PRIVATE")
        self.assertEqual(sum(row["path"] == "betaGroups" and row["method"] == "POST" for row in result["calls"]), 1)
        self.assertEqual(result["journal"]["intents"]["group:6837899703:Roomwave Public Beta"]["resource_id"], "public-group")

    def test_no_upload_or_notification_endpoints(self):
        result = self.scenario("approved")
        self.assertFalse(any("upload" in row["path"].lower() or "notification" in row["path"].lower() or "betaTesters" in row["path"] for row in result["calls"]))


if __name__ == "__main__":
    unittest.main()
