#!/usr/bin/env node
// Existing internal group only. No upload, tester creation, invitation, or notification.
import { APP, BUNDLE, VERSION, DEFAULT_CONTENT, MARKETING_URL, PRIVACY_URL,
  protectedClient, checkPublicURLs, validateContent, privateJSON, Journal } from './public-beta.mjs';
import { writeFileSync, mkdirSync, openSync, closeSync, fsyncSync, renameSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

export const INTERNAL_GROUP = '5a93cfb4-bd7c-4c0c-acbd-ade02816d8c1';
// Both distribution lanes must agree so internal reconciliation cannot invalidate
// the exact metadata readback required before an external review submission.
export const INTERNAL_WHATS_NEW = DEFAULT_CONTENT.whatsNew;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PROTECTED_REVIEW = new Set(['WAITING_FOR_REVIEW', 'IN_REVIEW', 'APPROVED']);
const attributes = row => row?.attributes ?? {};
const stamp = () => new Date().toISOString();

class Blocked extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
function requireThat(condition, code, message) { if (!condition) throw new Blocked(code, message); }
function safeID(value) {
  requireThat(typeof value === 'string' && /^[A-Za-z0-9-]{1,100}$/.test(value), 'BLOCKED_RESPONSE', 'Apple returned an invalid resource identifier');
  return value;
}
function resource(type, resourceID, attrs, relationships) {
  return { data: { type, ...(resourceID ? { id: resourceID } : {}), ...(attrs ? { attributes: attrs } : {}), ...(relationships ? { relationships } : {}) } };
}
function equalFields(actual, expected) { return Object.entries(expected).every(([key, value]) => actual[key] === value); }

async function list(api, path) {
  const rows = [], seen = new Set();
  for (let page = 0; path && page < 25; page += 1) {
    requireThat(!seen.has(path), 'BLOCKED_RESPONSE', 'Repeated Apple pagination');
    seen.add(path);
    const result = await api(path);
    requireThat(Array.isArray(result.data), 'BLOCKED_RESPONSE', 'Apple collection response is missing');
    rows.push(...result.data);
    path = result.links?.next || null;
  }
  requireThat(!path, 'BLOCKED_RESPONSE', 'Apple pagination exceeded the bounded inspection limit');
  return rows;
}

export async function inspectInternal(api, buildID) {
  requireThat(UUID.test(buildID ?? ''), 'BLOCKED_INPUT', 'An exact Apple build UUID is required');
  const app = (await api(`apps/${APP}`)).data;
  requireThat(app?.id === APP && attributes(app).bundleId === BUNDLE, 'BLOCKED_IDENTITY', 'App/bundle identity does not match the authorized app');
  const build = (await api(`builds/${buildID}`)).data;
  const owner = (await api(`builds/${buildID}/app`)).data;
  const version = (await api(`builds/${buildID}/preReleaseVersion`)).data;
  requireThat(build?.id === buildID && owner?.id === APP && attributes(owner).bundleId === BUNDLE,
    'BLOCKED_IDENTITY', 'Exact build does not belong to the authorized app/bundle');
  requireThat(attributes(version).version === VERSION && attributes(version).platform === 'IOS',
    'BLOCKED_IDENTITY', 'Build must belong to iOS version 0.3.0');
  const a = attributes(build);
  requireThat(a.processingState === 'VALID' && a.buildAudienceType === 'APP_STORE_ELIGIBLE' && a.expired === false
    && Number.isFinite(Date.parse(a.expirationDate)) && Date.parse(a.expirationDate) > Date.now(),
    'BLOCKED_BUILD', 'Build must be VALID, APP_STORE_ELIGIBLE and unexpired');
  const groups = await list(api, `apps/${APP}/betaGroups?limit=200`);
  const matching = groups.filter(row => row.id === INTERNAL_GROUP);
  requireThat(matching.length === 1 && attributes(matching[0]).isInternalGroup === true,
    'BLOCKED_GROUP', 'The existing authorized group must be present in this app and marked internal');
  const detail = (await api(`builds/${buildID}/buildBetaDetail`)).data;
  requireThat(detail?.id, 'BLOCKED_RESPONSE', 'Build beta detail is absent');
  const submission = (await api(`builds/${buildID}/betaAppReviewSubmission`)).data;
  const appLocales = await list(api, `apps/${APP}/betaAppLocalizations?limit=200`);
  const appEnglish = appLocales.filter(row => attributes(row).locale === 'en-US');
  requireThat(appEnglish.length === 1, 'BLOCKED_METADATA', 'Exactly one existing en-US app localization is required; none will be created');
  const buildLocales = (await list(api, `builds/${buildID}/betaBuildLocalizations?limit=200`))
    .filter(row => attributes(row).locale === 'en-US');
  requireThat(buildLocales.length <= 1, 'BLOCKED_METADATA', 'Ambiguous en-US build localization');
  const groupBuilds = await list(api, `betaGroups/${INTERNAL_GROUP}/relationships/builds?limit=200`);
  return { app, build, version, group: matching[0], detail, submission,
    appLocale: appEnglish[0], buildLocale: buildLocales[0] ?? null, groupBuilds };
}

export function verifyCompiledIdentity(receipt, build) {
  if (receipt === null || receipt === undefined) return false;
  requireThat(receipt.bundle === BUNDLE && receipt.version === VERSION && receipt.build === attributes(build).version
    && receipt.identity_verified === true && receipt.usesNonExemptEncryption === false
    && (!receipt.apple_build_id || receipt.apple_build_id === build.id),
    'BLOCKED_ENCRYPTION_EVIDENCE', 'Compiled receipt must match bundle/version/build, verify identity and explicitly declare usesNonExemptEncryption=false');
  return true;
}

function desiredApp(snapshot, content) {
  const feedbackEmail = attributes(snapshot.appLocale).feedbackEmail;
  requireThat(typeof feedbackEmail === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(feedbackEmail),
    'BLOCKED_METADATA', 'Existing feedback email is missing; no email will be guessed');
  return { description: content.description, marketingUrl: MARKETING_URL, privacyPolicyUrl: PRIVACY_URL, feedbackEmail };
}

function observed(snapshot, apply) {
  return { schema_version: 1, observed_at: stamp(), apply_requested: apply, app_id: APP, bundle_id: BUNDLE,
    version: VERSION, apple_build_id: snapshot.build.id, build: attributes(snapshot.build).version,
    processing_state: attributes(snapshot.build).processingState, group_id: INTERNAL_GROUP, group_verified_internal: true,
    internal_build_state: attributes(snapshot.detail).internalBuildState ?? null,
    external_review_state: attributes(snapshot.submission).betaReviewState ?? null,
    exact_build_associated: snapshot.groupBuilds.some(row => row.id === snapshot.build.id),
    uses_non_exempt_encryption: attributes(snapshot.build).usesNonExemptEncryption ?? null,
    auto_notify_enabled: attributes(snapshot.detail).autoNotifyEnabled,
    tester_installation_verified: false, external_review_contact_required: false };
}

export async function executeInternal({ api, buildID, apply = false, compiledIdentity = null, journal = null,
  content = DEFAULT_CONTENT, urlCheck = checkPublicURLs }) {
  let report = { schema_version: 1, observed_at: stamp(), app_id: APP, bundle_id: BUNDLE, version: VERSION,
    apple_build_id: UUID.test(buildID ?? '') ? buildID : null, apply_requested: apply, mutations: [], blockers: [],
    tester_installation_verified: false, external_review_contact_required: false };
  try {
    content = validateContent(content);
    let snapshot = await inspectInternal(api, buildID);
    report = { ...report, ...observed(snapshot, apply) };
    const compiledVerified = verifyCompiledIdentity(compiledIdentity, snapshot.build);
    report.compiled_identity_receipt_verified = compiledVerified;
    let declaration = attributes(snapshot.build).usesNonExemptEncryption;
    requireThat(declaration !== true, 'BLOCKED_ENCRYPTION_CONFLICT', 'Apple currently declares non-exempt encryption; inspect the conflict rather than overwriting it');
    requireThat(declaration === false || compiledVerified, 'BLOCKED_ENCRYPTION_EVIDENCE',
      'An unset Apple encryption declaration requires a matching compiled-app receipt with explicit usesNonExemptEncryption=false');
    let appAttributes = desiredApp(snapshot, content);
    await urlCheck();
    report.public_metadata_urls_verified = true;
    if (snapshot.buildLocale) journal?.observe(`build-locale:${buildID}:en-US`, snapshot.buildLocale.id);
    if (snapshot.groupBuilds.some(row => row.id === buildID)) journal?.observe(`associate:${INTERNAL_GROUP}:${buildID}`, buildID);
    const metadataMatches = value => equalFields(attributes(value.appLocale), appAttributes)
      && attributes(value.buildLocale).whatsNew === content.whatsNew
      && attributes(value.detail).autoNotifyEnabled === false && attributes(value.build).usesNonExemptEncryption === false;
    const preserveReview = value => requireThat(
      !PROTECTED_REVIEW.has(attributes(value.submission).betaReviewState) || metadataMatches(value),
      'BLOCKED_REVIEW', 'External review is pending or approved; internal reconciliation may preserve identical metadata but cannot rewrite it');
    preserveReview(snapshot);
    if (!apply) {
      report.state = 'PREFLIGHT_READY';
      report.metadata_staged = metadataMatches(snapshot);
      report.internal_beta_available = metadataMatches(snapshot) && report.exact_build_associated && report.internal_build_state === 'IN_BETA_TESTING';
      report.proposed_whats_new = content.whatsNew;
      report.proposed_metadata_fields = ['description', 'marketingUrl', 'privacyPolicyUrl', 'feedbackEmail (reused privately)'];
      report.encryption_change_required = declaration !== false;
      return report;
    }
    requireThat(journal, 'BLOCKED_STATE', 'Apply requires a persistent operator journal');
    // URL probes may take time. Re-read the review lock and exact build before
    // any mutation, including an unrelated internal association.
    snapshot = await inspectInternal(api, buildID);
    const refreshedCompiled = verifyCompiledIdentity(compiledIdentity, snapshot.build);
    declaration = attributes(snapshot.build).usesNonExemptEncryption;
    requireThat(declaration !== true, 'BLOCKED_ENCRYPTION_CONFLICT', 'Apple currently declares non-exempt encryption; inspect the conflict rather than overwriting it');
    requireThat(declaration === false || refreshedCompiled, 'BLOCKED_ENCRYPTION_EVIDENCE',
      'An unset Apple encryption declaration requires matching compiled evidence');
    appAttributes = desiredApp(snapshot, content);
    report = { ...report, ...observed(snapshot, apply) };
    preserveReview(snapshot);
    const patch = async (path, body) => {
      await api(path, 'PATCH', body);
      report.mutations.push({ method: 'PATCH', resource_path: path, response_observed: true });
    };
    const post = async (key, path, body) => {
      const response = await journal.postOnce(key, 'POST', path, body, api);
      report.mutations.push({ method: 'POST', resource_path: path, response_observed: true, resource_id: response.data?.id ?? null });
      return response;
    };
    if (declaration !== false) {
      requireThat(compiledVerified, 'BLOCKED_ENCRYPTION_EVIDENCE', 'Compiled encryption evidence is required');
      await patch(`builds/${buildID}`, resource('builds', buildID, { usesNonExemptEncryption: false }));
    }
    if (attributes(snapshot.detail).autoNotifyEnabled !== false) {
      await patch(`buildBetaDetails/${safeID(snapshot.detail.id)}`, resource('buildBetaDetails', snapshot.detail.id, { autoNotifyEnabled: false }));
    }
    if (!equalFields(attributes(snapshot.appLocale), appAttributes)) {
      await patch(`betaAppLocalizations/${safeID(snapshot.appLocale.id)}`, resource('betaAppLocalizations', snapshot.appLocale.id, appAttributes));
    }
    if (snapshot.buildLocale) {
      if (attributes(snapshot.buildLocale).whatsNew !== content.whatsNew) await patch(`betaBuildLocalizations/${safeID(snapshot.buildLocale.id)}`,
        resource('betaBuildLocalizations', snapshot.buildLocale.id, { whatsNew: content.whatsNew }));
    } else {
      await post(`build-locale:${buildID}:en-US`, 'betaBuildLocalizations', resource('betaBuildLocalizations', null,
        { locale: 'en-US', whatsNew: content.whatsNew }, { build: { data: { type: 'builds', id: buildID } } }));
    }
    if (!snapshot.groupBuilds.some(row => row.id === buildID)) {
      await post(`associate:${INTERNAL_GROUP}:${buildID}`, `betaGroups/${INTERNAL_GROUP}/relationships/builds`, { data: [{ type: 'builds', id: buildID }] });
    }
    snapshot = await inspectInternal(api, buildID);
    verifyCompiledIdentity(compiledIdentity, snapshot.build);
    report = { ...report, ...observed(snapshot, apply) };
    requireThat(metadataMatches(snapshot) && report.exact_build_associated, 'BLOCKED_READBACK', 'Expected metadata, encryption and exact internal group/build membership were not observed in readback');
    journal.observe(`build-locale:${buildID}:en-US`, snapshot.buildLocale.id);
    journal.observe(`associate:${INTERNAL_GROUP}:${buildID}`, buildID);
    report.metadata_staged = true;
    report.internal_beta_available = report.internal_build_state === 'IN_BETA_TESTING';
    requireThat(report.internal_beta_available, 'INTERNAL_ACTIVATION_PENDING', 'Membership is observed but Apple has not yet reported IN_BETA_TESTING; reconcile this build without re-uploading');
    report.state = 'INTERNAL_BETA_AVAILABLE';
    return report;
  } catch (error) {
    const known = error instanceof Blocked || (typeof error?.code === 'string' && /^BLOCKED_[A-Z_]+$/.test(error.code));
    report.state = known ? error.code : 'BLOCKED_ERROR';
    report.blockers.push({ code: report.state, reason: known ? error.message : 'Unexpected local failure; no private response, token or email values are printed' });
    return report;
  }
}

function atomicJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomUUID()}.tmp`;
  const descriptor = openSync(temporary, 'wx', 0o600);
  try { writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`); fsyncSync(descriptor); }
  finally { closeSync(descriptor); }
  renameSync(temporary, path);
}

export async function main(argv = process.argv.slice(2)) {
  let journal;
  const options = { apply: false, stateDir: 'build/release/testflight-operations' };
  try {
    requireThat(Number(process.versions.node.split('.')[0]) >= 22, 'BLOCKED_RUNTIME', 'Node 22 or later is required');
    if (argv.includes('--help')) {
      console.log('finalize-internal.mjs --build-id UUID [--apply] [--compiled-identity-receipt PATH] [--content-file REVIEWED_JSON] [--state-dir PRIVATE_DIRECTORY]');
      return 0;
    }
    for (let index = 0; index < argv.length; index += 1) {
      const flag = argv[index];
      if (flag === '--apply') { options.apply = true; continue; }
      const keys = { '--build-id': 'buildID', '--compiled-identity-receipt': 'identityPath', '--content-file': 'contentPath', '--state-dir': 'stateDir' };
      requireThat(keys[flag] && argv[index + 1] && !argv[index + 1].startsWith('--'), 'BLOCKED_INPUT', 'Unknown option or missing value');
      options[keys[flag]] = argv[++index];
    }
    requireThat(UUID.test(options.buildID ?? ''), 'BLOCKED_INPUT', 'An exact Apple build UUID is required');
    let compiledIdentity = null;
    if (options.identityPath) {
      try { compiledIdentity = privateJSON(options.identityPath); }
      catch { throw new Blocked('BLOCKED_INPUT', 'Compiled identity receipt could not be read'); }
    }
    const api = protectedClient();
    journal = new Journal(options.stateDir);
    const content = options.contentPath ? privateJSON(options.contentPath) : DEFAULT_CONTENT;
    const report = await executeInternal({ ...options, api, journal, compiledIdentity, content });
    atomicJSON(resolve(options.stateDir, `internal-${options.buildID}.json`), report);
    console.log(JSON.stringify(report, null, 2));
    return report.blockers.length ? 2 : 0;
  } catch (error) {
    const known = error instanceof Blocked || (typeof error?.code === 'string' && /^BLOCKED_[A-Z_]+$/.test(error.code));
    console.log(JSON.stringify({ state: known ? error.code : 'BLOCKED_ERROR', app_id: APP, version: VERSION,
      apply_requested: options.apply, blockers: [{ reason: known ? error.message : 'Initialization failed; no private values are printed' }] }, null, 2));
    return 2;
  } finally { journal?.close(); }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) process.exitCode = await main();
