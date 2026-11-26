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
if(Object.hasOwn(input,'phone')) contact.phone=input.phone;
const sourceSHA='a'.repeat(40);
const evidence={sourceSHA,
 compiledIdentity:{bundle:BUNDLE,version:VERSION,build:'1003.1',identity_verified:true,usesNonExemptEncryption:false},
 releaseReceipt:{commit:sourceSHA,app_store_app_id:APP,bundle_identifier:BUNDLE,version:VERSION,build:'1003.1',signature_verified:true,upload_accepted:true,ipa_sha256:'b'.repeat(64),
   workflow_run_id:'45774527262',workflow_run_number:3,workflow_run_attempt:1,
   allocation_id:'github:timelabs-npo/blueshoes-roomwave:45774527262:1'},
 processingReceipt:{app_id:APP,version:VERSION,build:'1003.1',apple_build_id:buildID,apple_processing:'VALID'},
};
if(input.missingEvidence) delete evidence[input.missingEvidence];
for(const change of input.receiptChanges||[]) {
 if(change.receipt==='sourceSHA') evidence.sourceSHA=change.value;
 else if(change.remove) delete evidence[change.receipt][change.key];
 else evidence[change.receipt][change.key]=change.value;
}
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
   if(body.data.type==='betaGroups' && body.data.attributes.publicLinkEnabled) {
     row.attributes.publicLink='https://testflight.apple.com/join/Observed123';
     if(input.readbackDrift==='membership') state.groupBuilds=[];
     if(input.readbackDrift==='description') state.appLocales[0].attributes.description='Changed after enabling';
     if(input.readbackDrift==='whatsNew') state.buildLocales[0].attributes.whatsNew='Changed after enabling';
     if(input.readbackDrift==='reviewNotes') state.review.attributes.notes='Changed after enabling';
     if(input.readbackDrift==='notification') state.detail.attributes.autoNotifyEnabled=true;
     if(input.readbackDrift==='build') state.build.attributes.version='1003.9';
   }
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
if(input.scenario==='wrong-build-number') state.build.attributes.version='1003.2';
if(input.scenario==='internal-only') state.build.attributes.buildAudienceType='INTERNAL_ONLY';
if(input.scenario==='expired') state.build.attributes.expired=true;
if(input.scenario==='extra-locale') state.appLocales.push({id:'fr',attributes:{locale:'fr-FR',description:'Old chemistry'}});
if(input.scenario==='other-build') {
 state.groups.push({id:'public-group',attributes:{name:GROUP_NAME,isInternalGroup:false,hasAccessToAllBuilds:false}});
 state.groupBuilds=[{type:'builds',id:'different-build'}];
}
const journal=new Journal(input.directory);
const base={api,journal,buildID,...evidence,contact:input.scenario==='missing-contact'?null:contact,urlCheck:async()=>true};
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
        for scenario in ("wrong-bundle", "wrong-version", "wrong-build-number", "internal-only", "expired", "other-build", "extra-locale"):
            with self.subTest(scenario=scenario):
                result = self.scenario(scenario, action="stage", apply=True)
                self.assertTrue(result["results"][-1]["state"].startswith("BLOCKED_"))
                self.assertEqual(self.writes(result), [])

    def test_all_promotion_actions_require_reviewed_source_and_all_three_receipts(self):
        for action in ("preflight", "stage", "submit", "enable-public-link"):
            for field in ("sourceSHA", "compiledIdentity", "releaseReceipt", "processingReceipt"):
                with self.subTest(action=action, missing=field):
                    result = self.scenario(action=action, apply=action != "preflight", missingEvidence=field)
                    self.assertEqual(result["results"][-1]["state"], "BLOCKED_PROMOTION_EVIDENCE")
                    self.assertEqual(result["calls"], [])

    def test_receipt_chain_rejects_wrong_source_identity_or_unaccepted_upload(self):
        cases = (
            ("sourceSHA", None, "a" * 39),
            ("sourceSHA", None, "c" * 40),
            ("releaseReceipt", "commit", "c" * 40),
            ("releaseReceipt", "app_store_app_id", "different-app"),
            ("releaseReceipt", "bundle_identifier", "different.bundle"),
            ("releaseReceipt", "version", "0.2.0"),
            ("releaseReceipt", "build", "1003.2"),
            ("releaseReceipt", "signature_verified", False),
            ("releaseReceipt", "upload_accepted", False),
            ("releaseReceipt", "ipa_sha256", "invalid-digest"),
            ("compiledIdentity", "build", "1003.2"),
            ("compiledIdentity", "identity_verified", False),
            ("compiledIdentity", "usesNonExemptEncryption", None),
            ("compiledIdentity", "apple_build_id", "99999999-2222-3333-4444-555555555555"),
            ("processingReceipt", "app_id", "different-app"),
            ("processingReceipt", "version", "0.2.0"),
            ("processingReceipt", "build", "1003.2"),
            ("processingReceipt", "apple_build_id", "99999999-2222-3333-4444-555555555555"),
            ("processingReceipt", "apple_processing", "PROCESSING"),
            ("processingReceipt", "source_sha", "c" * 40),
        )
        for receipt, key, value in cases:
            with self.subTest(receipt=receipt, key=key):
                result = self.scenario(action="stage", apply=True,
                                       receiptChanges=[{"receipt": receipt, "key": key, "value": value}])
                self.assertEqual(result["results"][-1]["state"], "BLOCKED_PROMOTION_EVIDENCE")
                self.assertEqual(result["calls"], [])

    def test_verified_receipt_identity_is_preserved_in_promotion_report(self):
        report = self.scenario("approved")["results"][-1]
        self.assertEqual(report["source_sha"], "a" * 40)
        self.assertEqual(report["ipa_sha256"], "b" * 64)
        self.assertTrue(report["promotion_evidence_verified"])
        self.assertEqual(report["build"], "1003.1")
        self.assertEqual(report["workflow_run_id"], "45774527262")
        self.assertEqual(report["workflow_run_number"], 3)
        self.assertEqual(report["workflow_run_attempt"], 1)
        self.assertEqual(report["allocation_id"], "github:timelabs-npo/blueshoes-roomwave:45774527262:1")

    def test_legacy_receipts_without_observed_allocation_cannot_promote(self):
        for field in ("workflow_run_id", "workflow_run_number", "workflow_run_attempt", "allocation_id"):
            with self.subTest(field=field):
                result = self.scenario(action="stage", apply=True,
                    receiptChanges=[{"receipt": "releaseReceipt", "key": field, "remove": True}])
                self.assertEqual(result["results"][-1]["state"], "BLOCKED_PROMOTION_EVIDENCE")
                self.assertEqual(result["calls"], [])

    def test_allocation_tuple_rejects_tampering_and_conflicting_optional_bindings(self):
        changes = [
            [{"receipt": "releaseReceipt", "key": "workflow_run_number", "value": 99},
             {"receipt": "releaseReceipt", "key": "workflow_run_attempt", "value": 2}],
        ]
        for receipt in ("compiledIdentity", "releaseReceipt", "processingReceipt"):
            for key, value in (("workflow_run_id", "45774527263"), ("workflow_run_number", 99),
                               ("workflow_run_attempt", 2), ("allocation_id", "github:timelabs-npo/blueshoes-roomwave:45774527263:1"),
                               ("repository", "another/repository"), ("run_id", "45774527263"),
                               ("run_number", 99), ("run_attempt", 2), ("build_number", "1099.2")):
                changes.append([{"receipt": receipt, "key": key, "value": value}])
        for key, value in (("workflow_run_id", True), ("workflow_run_number", "3"),
                           ("workflow_run_number", True), ("workflow_run_attempt", "1")):
            changes.append([{"receipt": "releaseReceipt", "key": key, "value": value}])
        for mutation in changes:
            with self.subTest(mutation=mutation):
                result = self.scenario(action="stage", apply=True, receiptChanges=mutation)
                self.assertEqual(result["results"][-1]["state"], "BLOCKED_PROMOTION_EVIDENCE")
                self.assertEqual(result["calls"], [])

    def test_matching_optional_workflow_bindings_are_accepted(self):
        bindings = {"workflow_run_id": "45774527262", "workflow_run_number": 3, "workflow_run_attempt": 1,
                    "allocation_id": "github:timelabs-npo/blueshoes-roomwave:45774527262:1",
                    "run_id": "45774527262", "run_number": 3, "run_attempt": 1,
                    "repository": "timelabs-npo/blueshoes-roomwave", "build_number": "1003.1"}
        mutations = [{"receipt": receipt, "key": key, "value": value}
                     for receipt in ("compiledIdentity", "releaseReceipt", "processingReceipt")
                     for key, value in bindings.items()]
        result = self.scenario(action="preflight", receiptChanges=mutations)
        self.assertEqual(result["results"][-1]["state"], "PREFLIGHT_READY")
        self.assertTrue(result["results"][-1]["promotion_evidence_verified"])

    def test_cli_reads_required_receipts_before_protected_client_initialization(self):
        build_id = "11111111-2222-3333-4444-555555555555"
        source = "a" * 40
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            receipts = {
                "compiled-identity-receipt": {"bundle": "org.timelabs.moleculefoundry", "version": "0.3.0",
                    "build": "1003.1", "identity_verified": True, "usesNonExemptEncryption": False},
                "release-receipt": {"commit": source, "app_store_app_id": "6837899703",
                    "bundle_identifier": "org.timelabs.moleculefoundry", "version": "0.3.0", "build": "1003.1",
                    "signature_verified": True, "upload_accepted": True, "ipa_sha256": "b" * 64,
                    "workflow_run_id": "45774527262", "workflow_run_number": 3, "workflow_run_attempt": 1,
                    "allocation_id": "github:timelabs-npo/blueshoes-roomwave:45774527262:1"},
                "processing-receipt": {"app_id": "6837899703", "version": "0.3.0", "build": "1003.1",
                    "apple_build_id": build_id, "apple_processing": "VALID"},
            }
            receipt_args = []
            for name, value in receipts.items():
                path = folder / f"{name}.json"
                path.write_text(json.dumps(value), encoding="utf-8")
                receipt_args.extend([f"--{name}", str(path)])
            command = [shutil.which("node"), str(HELPER), "preflight", "--build-id", build_id,
                       "--state-dir", str(folder / "operator")]
            cases = (
                ([], "BLOCKED_PROMOTION_EVIDENCE"),
                (receipt_args, "BLOCKED_PROMOTION_EVIDENCE"),
                (receipt_args + ["--source-sha", "c" * 40], "BLOCKED_PROMOTION_EVIDENCE"),
                (receipt_args + ["--source-sha", source], "BLOCKED_IDENTITY"),
            )
            for arguments, state in cases:
                with self.subTest(state=state, arguments=len(arguments)):
                    # Empty environment deliberately prevents any real Apple key,
                    # protected identity or network operation from being reached.
                    result = subprocess.run(command + arguments, env={}, text=True,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(json.loads(result.stdout)["state"], state)
            self.assertFalse((folder / "operator").exists())

    def test_contact_and_public_privacy_url_are_real_preconditions(self):
        for scenario, code in (("missing-contact", "BLOCKED_INPUT"), ("url-failure", "BLOCKED_METADATA")):
            result = self.scenario(scenario, action="stage", apply=True)
            self.assertEqual(result["results"][-1]["state"], code)
            self.assertEqual(self.writes(result), [])

    def test_international_phone_requires_real_digit_structure_after_normalization(self):
        for phone in ("+1------", "+1234567", "+1234567890123456", "+01234567890", "++12025550123", "+1-ABC-555-0123"):
            with self.subTest(phone=phone):
                result = self.scenario(action="stage", apply=True, phone=phone)
                self.assertEqual(result["results"][-1]["state"], "BLOCKED_INPUT")
                self.assertEqual(self.writes(result), [])
        formatted = self.scenario(action="stage", apply=True, phone="+1 (202) 555-0123")
        self.assertEqual(formatted["results"][-1]["state"], "STAGED_PRIVATE")

    def test_stage_correct_whatsnew_and_disabled_capped_external_group(self):
        result = self.scenario(action="stage", apply=True)
        self.assertEqual(result["results"][-1]["state"], "STAGED_PRIVATE")
        group = result["state"]["groups"][-1]["attributes"]
        self.assertEqual(group["name"], "Twitter Surfer Public Beta")
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

    def test_public_link_final_readback_rechecks_full_staging_and_receipt_binding(self):
        for drift in ("membership", "description", "whatsNew", "reviewNotes", "notification", "build"):
            with self.subTest(drift=drift):
                result = self.scenario("approved", readbackDrift=drift)
                report = result["results"][-1]
                expected = "BLOCKED_PROMOTION_EVIDENCE" if drift == "build" else "BLOCKED_READBACK"
                self.assertEqual(report["state"], expected)
                self.assertNotIn("public_url", report)
                self.assertTrue(result["state"]["groups"][-1]["attributes"]["publicLinkEnabled"])
                self.assertTrue(report["mutations"], "The observed PATCH must survive a failed final gate")

    def test_rejected_submission_is_never_automatically_resubmitted(self):
        result = self.scenario("rejected")
        self.assertEqual(result["results"][-1]["state"], "BLOCKED_REVIEW")
        self.assertFalse(any(row["path"] == "betaAppReviewSubmissions" for row in self.writes(result)))

    def test_unknown_post_outcome_keeps_intent_and_blocks_duplicate_creation(self):
        result = self.scenario("lost-create")
        self.assertEqual(result["results"][-1]["state"], "BLOCKED_RECONCILE")
        self.assertEqual(sum(row["path"] == "betaGroups" and row["method"] == "POST" for row in result["calls"]), 1)
        self.assertEqual(result["journal"]["intents"]["group:6837899703:Twitter Surfer Public Beta"]["state"], "INTENT_RECORDED")

    def test_lost_response_with_observed_group_reuses_exact_resource(self):
        result = self.scenario("lost-create-observed")
        self.assertEqual(result["results"][-1]["state"], "STAGED_PRIVATE")
        self.assertEqual(sum(row["path"] == "betaGroups" and row["method"] == "POST" for row in result["calls"]), 1)
        self.assertEqual(result["journal"]["intents"]["group:6837899703:Twitter Surfer Public Beta"]["resource_id"], "public-group")

    def test_no_upload_or_notification_endpoints(self):
        result = self.scenario("approved")
        self.assertFalse(any("upload" in row["path"].lower() or "notification" in row["path"].lower() or "betaTesters" in row["path"] for row in result["calls"]))


if __name__ == "__main__":
    unittest.main()
