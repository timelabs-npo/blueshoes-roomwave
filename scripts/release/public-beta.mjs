#!/usr/bin/env node
// External-beta staging only. Never uploads, signs, invites, or sends notifications.
import { createPrivateKey, sign, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, openSync, closeSync, fsyncSync, renameSync, unlinkSync, existsSync,
  fstatSync, readSync, constants } from 'node:fs';
import { resolve, dirname, relative, isAbsolute, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const APP = '6837899703';
export const BUNDLE = 'org.timelabs.moleculefoundry';
export const VERSION = '0.3.0';
export const GROUP_NAME = 'Roomwave Public Beta';
export const CAP = 200;
export const API_ORIGIN = 'https://api.appstoreconnect.apple.com';
export const MARKETING_URL = 'https://github.com/timelabs-npo/blueshoes-roomwave';
export const PRIVACY_URL = `${MARKETING_URL}/blob/main/docs/PRIVACY.md`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SOURCE_SHA = /^[0-9a-f]{40}$/i;
const DIGEST = /^[0-9a-f]{64}$/i;
const APPROVED_EXTERNAL = new Set(['BETA_APPROVED', 'IN_BETA_TESTING']);
const ACTIONS = new Set(['preflight', 'stage', 'submit', 'enable-public-link']);

export const DEFAULT_CONTENT = Object.freeze({
  description: 'Roomwave is a one-touch kinetic surfing score-attack game. Hold to compress, release to launch, and hold in the air to dive. Ride sculpted neon courses, collect aerial rings, and build flow through clean landings. Learn three courses, improve your personal best, and share a result when you choose. This beta focuses on the arcade experience; photo and LiDAR creation are optional and do not block first play.',
  whatsNew: '0.3.0 arcade rebuild. Please test hold/release/dive controls, the three courses, clean landings, shields, rings and combo scoring. Hold to compress, release to launch, hold in the air to dive, and release before touchdown for a clean landing. Check pause and background recovery, sound and haptics, saved personal bests, and player-initiated result sharing. Report unreadable hazards, unfair collisions, input problems or performance issues with your device and OS version. Scores come from gameplay; social engagement does not add points.',
  reviewNotes: 'Roomwave is the arcade rebuild under the existing org.timelabs.moleculefoundry bundle. The core game is available as a guest without signing in. Choose a course and tap Play. Hold to compress, release to launch, and hold while airborne to dive. Release before touchdown for a clean landing. Pause, results, retry and local bests are part of the review flow. Photo/LiDAR creation is optional; no camera permission is needed for the core game. Sharing is initiated and confirmed by the player. No social account or purchases are required.',
});

class Blocked extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function ensure(condition, code, message) {
  if (!condition) throw new Blocked(code, message);
}

function id(value) {
  ensure(typeof value === 'string' && /^[A-Za-z0-9-]{1,100}$/.test(value), 'BLOCKED_RESPONSE', 'Apple returned an invalid resource identifier');
  return value;
}

function stamp() { return new Date().toISOString(); }
function attrs(row) { return row?.attributes ?? {}; }
function same(left, right) { return Object.entries(right).every(([key, value]) => left[key] === value); }
function resource(type, resourceID, attributes, relationships) {
  return { data: { type, ...(resourceID ? { id: resourceID } : {}), ...(attributes ? { attributes } : {}), ...(relationships ? { relationships } : {}) } };
}
function relationship(type, resourceID) { return { data: { type, id: resourceID } }; }

export function validateContent(content) {
  for (const field of ['description', 'whatsNew', 'reviewNotes']) {
    ensure(typeof content?.[field] === 'string' && content[field].trim().length > 20 && content[field].length <= 4000,
      'BLOCKED_INPUT', `Reviewed ${field} must contain 21–4000 characters`);
  }
  return Object.fromEntries(['description', 'whatsNew', 'reviewNotes'].map(key => [key, content[key].trim()]));
}

export function validContact(contact) {
  const phone = typeof contact?.phone === 'string' ? contact.phone.trim() : '';
  const international = /^\+[1-9][0-9 ()-]{6,24}$/.test(phone)
    && /^\+[1-9][0-9]{7,14}$/.test(phone.replace(/[ ()-]/g, ''));
  return typeof contact?.firstName === 'string' && !!contact.firstName.trim()
    && typeof contact?.lastName === 'string' && !!contact.lastName.trim()
    && typeof contact?.email === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contact.email)
    && international
    && Object.values(contact).every(value => typeof value !== 'string' || value.length <= 250);
}

// These are protected operator inputs, not self-authenticating attestations.
// The operator must retrieve all three receipts from the trusted release run
// for the independently reviewed source SHA. Never synthesize missing receipts.
export function verifyPromotionEvidence({ sourceSHA, compiledIdentity, releaseReceipt, processingReceipt }, buildID) {
  ensure(UUID.test(buildID ?? ''), 'BLOCKED_INPUT', 'An exact Apple build UUID is required');
  ensure(typeof sourceSHA === 'string' && SOURCE_SHA.test(sourceSHA),
    'BLOCKED_PROMOTION_EVIDENCE', 'An independently reviewed full source SHA is required');
  ensure(compiledIdentity && releaseReceipt && processingReceipt,
    'BLOCKED_PROMOTION_EVIDENCE', 'Compiled identity, accepted release and VALID Apple processing receipts are required');
  const build = releaseReceipt.build;
  ensure(typeof build === 'string' && /^[0-9]+(?:\.[0-9]+){0,2}$/.test(build)
    && releaseReceipt.commit === sourceSHA && releaseReceipt.app_store_app_id === APP
    && releaseReceipt.bundle_identifier === BUNDLE && releaseReceipt.version === VERSION
    && releaseReceipt.signature_verified === true && releaseReceipt.upload_accepted === true
    && typeof releaseReceipt.ipa_sha256 === 'string' && DIGEST.test(releaseReceipt.ipa_sha256),
    'BLOCKED_PROMOTION_EVIDENCE', 'Accepted signed release receipt must match the reviewed source, app, bundle, version and build and contain an IPA digest');
  ensure(compiledIdentity.bundle === BUNDLE && compiledIdentity.version === VERSION && compiledIdentity.build === build
    && compiledIdentity.identity_verified === true && compiledIdentity.usesNonExemptEncryption === false,
    'BLOCKED_PROMOTION_EVIDENCE', 'Compiled identity must match the exact release and its explicit encryption declaration');
  ensure(processingReceipt.app_id === APP && processingReceipt.version === VERSION && processingReceipt.build === build
    && processingReceipt.apple_build_id === buildID && processingReceipt.apple_processing === 'VALID',
    'BLOCKED_PROMOTION_EVIDENCE', 'Processing receipt must bind the accepted release to this exact VALID Apple build UUID');
  // Existing producers may add these bindings. If supplied, none may conflict.
  const optional = { source_sha: sourceSHA, commit: sourceSHA, app_id: APP, app_store_app_id: APP,
    bundle: BUNDLE, bundle_id: BUNDLE, bundle_identifier: BUNDLE, apple_build_id: buildID,
    ipa_sha256: releaseReceipt.ipa_sha256 };
  for (const receipt of [compiledIdentity, releaseReceipt, processingReceipt]) {
    for (const [key, expected] of Object.entries(optional)) {
      ensure(!Object.hasOwn(receipt, key) || receipt[key] === expected,
        'BLOCKED_PROMOTION_EVIDENCE', 'An optional receipt identity binding conflicts with the reviewed release');
    }
  }
  return Object.freeze({ source_sha: sourceSHA, app_id: APP, bundle_id: BUNDLE, version: VERSION,
    build, apple_build_id: buildID, ipa_sha256: releaseReceipt.ipa_sha256,
    promotion_evidence_verified: true, receipt_provenance: 'operator-trusted-release-artifact' });
}

function storedContact(review) {
  const value = attrs(review);
  return { firstName: value.contactFirstName, lastName: value.contactLastName, email: value.contactEmail, phone: value.contactPhone };
}

function contactAttributes(contact, content) {
  return { contactFirstName: contact.firstName.trim(), contactLastName: contact.lastName.trim(),
    contactEmail: contact.email.trim(), contactPhone: contact.phone.trim(), demoAccountRequired: false, notes: content.reviewNotes };
}

export function protectedClient(environment = process.env, fetchImpl = fetch) {
  ensure(environment.APP_STORE_APP_ID === APP, 'BLOCKED_IDENTITY', 'APP_STORE_APP_ID must identify the authorized existing app');
  for (const field of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY_P8_BASE64']) {
    ensure(environment[field], 'BLOCKED_ACCESS', `Missing protected environment variable: ${field}`);
  }
  let key;
  try { key = createPrivateKey(Buffer.from(environment.ASC_PRIVATE_KEY_P8_BASE64, 'base64')); }
  catch { throw new Blocked('BLOCKED_ACCESS', 'Protected signing key could not be loaded'); }
  ensure(key.asymmetricKeyType === 'ec' && key.asymmetricKeyDetails?.namedCurve === 'prime256v1',
    'BLOCKED_ACCESS', 'Protected signing key must be an ES256 P-256 key');
  function token() {
    const now = Math.floor(Date.now() / 1000);
    const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const input = `${encode({ alg: 'ES256', kid: environment.ASC_KEY_ID, typ: 'JWT' })}.${encode({ iss: environment.ASC_ISSUER_ID, iat: now, exp: now + 300, aud: 'appstoreconnect-v1' })}`;
    return `${input}.${sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  }
  return async function api(path, method = 'GET', body) {
    const url = new URL(path.startsWith('https:') ? path : `/v1/${path}`, API_ORIGIN);
    ensure(url.origin === API_ORIGIN && url.pathname.startsWith('/v1/') && !url.username && !url.password,
      'BLOCKED_RESPONSE', 'Refused an Apple API URL outside the fixed origin');
    let response;
    try {
      response = await fetchImpl(url, { method, redirect: 'error', signal: AbortSignal.timeout(30000),
        headers: { Authorization: `Bearer ${token()}`, Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}) });
    } catch { throw new Blocked('BLOCKED_ACCESS', `Apple ${method} response was not observed; reconcile before retrying a write`); }
    if (!response.ok) {
      // Never print Apple error detail, which may echo contact fields or other private data.
      throw new Blocked(response.status === 401 || response.status === 403 ? 'BLOCKED_ACCESS' : 'BLOCKED_APPLE',
        `Apple ${method} returned HTTP ${response.status}; no automatic retry`);
    }
    if (response.status === 204) return { data: null };
    try { return await response.json(); }
    catch { throw new Blocked('BLOCKED_RESPONSE', 'Apple returned an unreadable response; reconcile before retrying a write'); }
  };
}

async function list(api, path) {
  const rows = [];
  const seen = new Set();
  for (let page = 0; path && page < 25; page += 1) {
    ensure(!seen.has(path), 'BLOCKED_RESPONSE', 'Apple pagination repeated a page');
    seen.add(path);
    const response = await api(path);
    ensure(Array.isArray(response.data), 'BLOCKED_RESPONSE', 'Expected an Apple resource collection');
    rows.push(...response.data);
    path = response.links?.next || null;
  }
  ensure(!path, 'BLOCKED_RESPONSE', 'Apple pagination exceeded the bounded inspection limit');
  return rows;
}

export async function inspect(api, buildID) {
  ensure(UUID.test(buildID ?? ''), 'BLOCKED_INPUT', 'An exact Apple build UUID is required');
  const app = (await api(`apps/${APP}`)).data;
  ensure(app?.id === APP && attrs(app).bundleId === BUNDLE, 'BLOCKED_IDENTITY', 'App ID or bundle identity differs from the authorized app');
  const build = (await api(`builds/${buildID}`)).data;
  const buildApp = (await api(`builds/${buildID}/app`)).data;
  const version = (await api(`builds/${buildID}/preReleaseVersion`)).data;
  ensure(build?.id === buildID && buildApp?.id === APP && attrs(buildApp).bundleId === BUNDLE,
    'BLOCKED_IDENTITY', 'Exact build does not belong to the authorized app and bundle');
  ensure(attrs(version).version === VERSION && attrs(version).platform === 'IOS', 'BLOCKED_IDENTITY', 'Build must belong to iOS version 0.3.0');
  ensure(attrs(build).processingState === 'VALID' && attrs(build).buildAudienceType === 'APP_STORE_ELIGIBLE'
    && attrs(build).expired === false, 'BLOCKED_BUILD', 'Build must be VALID, APP_STORE_ELIGIBLE and unexpired');
  const expiration = Date.parse(attrs(build).expirationDate);
  ensure(Number.isFinite(expiration) && expiration > Date.now(), 'BLOCKED_BUILD', 'Build expiration is absent or already passed');
  const detail = (await api(`builds/${buildID}/buildBetaDetail`)).data;
  const submission = (await api(`builds/${buildID}/betaAppReviewSubmission`)).data;
  const review = (await api(`apps/${APP}/betaAppReviewDetail`)).data;
  const appLocales = await list(api, `apps/${APP}/betaAppLocalizations?limit=200`);
  const buildLocales = await list(api, `builds/${buildID}/betaBuildLocalizations?limit=200`);
  const groups = await list(api, `apps/${APP}/betaGroups?limit=200`);
  const matching = groups.filter(group => attrs(group).name === GROUP_NAME);
  ensure(matching.length <= 1, 'BLOCKED_CONFLICT', 'More than one beta group has the target name; coordinator must resolve it');
  const group = matching[0] ?? null;
  if (group) {
    ensure(attrs(group).isInternalGroup === false && attrs(group).hasAccessToAllBuilds === false,
      'BLOCKED_GROUP', 'Existing target group must be external and restricted to explicitly associated builds');
  }
  const groupBuilds = group ? await list(api, `betaGroups/${id(group.id)}/relationships/builds?limit=200`) : [];
  ensure(groupBuilds.every(row => row.id === buildID), 'BLOCKED_GROUP', 'Target group contains other builds; this helper will not expose or remove them');
  ensure(appLocales.filter(row => attrs(row).locale === 'en-US').length <= 1
    && buildLocales.filter(row => attrs(row).locale === 'en-US').length <= 1, 'BLOCKED_CONFLICT', 'Duplicate en-US localization records');
  ensure(appLocales.every(row => attrs(row).locale === 'en-US') && buildLocales.every(row => attrs(row).locale === 'en-US'),
    'BLOCKED_LOCALIZATION', 'Additional locales need reviewed game translations before this en-US staging helper can proceed');
  ensure(review && detail, 'BLOCKED_RESPONSE', 'Beta review/detail resources are missing');
  return { app, build, version, detail, submission, review, appLocales, buildLocales, groups, group, groupBuilds };
}

function expectedApp(snapshot, content) {
  const old = snapshot.appLocales.find(row => attrs(row).locale === 'en-US');
  const feedbackEmail = attrs(old).feedbackEmail;
  ensure(typeof feedbackEmail === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(feedbackEmail),
    'BLOCKED_INPUT', 'Existing feedback email is missing; a real protected value must be supplied through the existing Apple record');
  return { description: content.description, feedbackEmail, marketingUrl: MARKETING_URL, privacyPolicyUrl: PRIVACY_URL };
}

function staged(snapshot, content) {
  const appLocale = snapshot.appLocales.find(row => attrs(row).locale === 'en-US');
  const buildLocale = snapshot.buildLocales.find(row => attrs(row).locale === 'en-US');
  return same(attrs(appLocale), expectedApp(snapshot, content)) && attrs(buildLocale).whatsNew === content.whatsNew
    && validContact(storedContact(snapshot.review)) && attrs(snapshot.review).demoAccountRequired === false
    && attrs(snapshot.review).notes === content.reviewNotes && attrs(snapshot.detail).autoNotifyEnabled === false
    && snapshot.group && attrs(snapshot.group).publicLinkLimitEnabled === true && attrs(snapshot.group).publicLinkLimit === CAP
    && snapshot.groupBuilds.some(row => row.id === snapshot.build.id);
}

function approved(snapshot) {
  return attrs(snapshot.submission).betaReviewState === 'APPROVED'
    && APPROVED_EXTERNAL.has(attrs(snapshot.detail).externalBuildState);
}

export async function checkPublicURLs(fetchImpl = fetch) {
  for (const url of [MARKETING_URL, PRIVACY_URL]) {
    let response;
    try { response = await fetchImpl(url, { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(20000) }); }
    catch { throw new Blocked('BLOCKED_METADATA', 'Marketing/privacy URL readiness could not be verified'); }
    await response.body?.cancel();
    ensure(response.status === 200, 'BLOCKED_METADATA', 'Marketing/privacy URL must return an observed HTTP 200 before staging');
  }
  return true;
}

function writeAtomic(path, data) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomUUID()}.tmp`;
  const descriptor = openSync(temporary, 'wx', 0o600);
  try { writeFileSync(descriptor, `${JSON.stringify(data, null, 2)}\n`); fsyncSync(descriptor); }
  finally { closeSync(descriptor); }
  renameSync(temporary, path);
}

export class Journal {
  constructor(directory) {
    this.directory = resolve(directory);
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    this.path = resolve(this.directory, 'public-beta-journal.json');
    this.lock = resolve(this.directory, 'public-beta.lock');
    this.handle = null;
    try { this.handle = openSync(this.lock, 'wx', 0o600); }
    catch { throw new Blocked('BLOCKED_LOCK', 'A public-beta operator lock exists; inspect the original process before clearing a stale lock'); }
    try {
      writeFileSync(this.handle, JSON.stringify({ pid: process.pid, started_at: stamp() }));
      this.data = existsSync(this.path) ? JSON.parse(readFileSync(this.path, 'utf8')) : { schema_version: 1, app_id: APP, intents: {} };
      ensure(this.data.schema_version === 1 && this.data.app_id === APP, 'BLOCKED_STATE', 'Journal identity/schema mismatch');
    } catch (error) { this.close(); throw error; }
  }
  save() { writeAtomic(this.path, this.data); }
  observe(key, resourceID) {
    const old = this.data.intents[key];
    ensure(!old?.resource_id || old.resource_id === resourceID, 'BLOCKED_CONFLICT', 'Observed Apple resource ID differs from the preserved write receipt');
    if (old && old.state !== 'OBSERVED') {
      this.data.intents[key] = { ...old, state: 'OBSERVED', resource_id: resourceID, observed_at: stamp() };
      this.save();
    }
  }
  async postOnce(key, method, path, body, api) {
    ensure(!this.data.intents[key], 'BLOCKED_RECONCILE', 'A write intent already exists without matching readback; inspect Apple state instead of repeating it');
    this.data.intents[key] = { state: 'INTENT_RECORDED', method, resource_path: path, started_at: stamp() };
    this.save();
    const result = await api(path, method, body);
    this.data.intents[key] = { ...this.data.intents[key], state: 'RESPONSE_OBSERVED', resource_id: result.data?.id ?? null, observed_at: stamp() };
    this.save();
    return result;
  }
  close() {
    if (this.handle !== null) { closeSync(this.handle); this.handle = null; unlinkSync(this.lock); }
  }
}

function sanitized(snapshot, action, apply) {
  return { schema_version: 1, observed_at: stamp(), action, apply_requested: apply, app_id: APP, bundle_id: BUNDLE,
    version: VERSION, apple_build_id: snapshot.build.id, build: attrs(snapshot.build).version,
    processing_state: attrs(snapshot.build).processingState, build_audience_type: attrs(snapshot.build).buildAudienceType,
    external_build_state: attrs(snapshot.detail).externalBuildState, review_state: attrs(snapshot.submission).betaReviewState ?? null,
    review_submission_id: snapshot.submission?.id ?? null, group_id: snapshot.group?.id ?? null,
    exact_build_associated: snapshot.groupBuilds.some(row => row.id === snapshot.build.id),
    public_link_enabled: attrs(snapshot.group).publicLinkEnabled === true, public_link_limit: attrs(snapshot.group).publicLinkLimit ?? null,
    review_contact_present: validContact(storedContact(snapshot.review)),
    feedback_email_present: snapshot.appLocales.some(row => !!attrs(row).feedbackEmail),
    auto_notify_enabled: attrs(snapshot.detail).autoNotifyEnabled, tester_access_verified: false,
    mutations: [], blockers: [] };
}

export async function execute({ api, journal, buildID, action = 'preflight', apply = false, contact = null,
  sourceSHA, compiledIdentity, releaseReceipt, processingReceipt,
  content = DEFAULT_CONTENT, urlCheck = checkPublicURLs }) {
  let report = { schema_version: 1, observed_at: stamp(), action, apply_requested: apply, app_id: APP, bundle_id: BUNDLE,
    version: VERSION, apple_build_id: UUID.test(buildID ?? '') ? buildID : null, mutations: [], blockers: [], tester_access_verified: false };
  try {
    ensure(ACTIONS.has(action), 'BLOCKED_INPUT', 'Unknown public-beta action');
    ensure(!(action === 'preflight' && apply), 'BLOCKED_INPUT', 'Preflight never accepts --apply');
    content = validateContent(content);
    const promotion = verifyPromotionEvidence({ sourceSHA, compiledIdentity, releaseReceipt, processingReceipt }, buildID);
    const inspectBound = async () => {
      const value = await inspect(api, buildID);
      ensure(attrs(value.build).version === promotion.build,
        'BLOCKED_PROMOTION_EVIDENCE', 'Live Apple build number differs from the reviewed compiled/upload/processing receipts');
      return value;
    };
    let snapshot = await inspectBound();
    report = { ...sanitized(snapshot, action, apply), ...promotion };
    const groupKey = `group:${APP}:${GROUP_NAME}`;
    const submitKey = `submission:${buildID}`;
    if (snapshot.group) journal?.observe(groupKey, snapshot.group.id);
    if (snapshot.submission) journal?.observe(submitKey, snapshot.submission.id);
    for (const row of snapshot.appLocales) journal?.observe(`app-locale:${APP}:${attrs(row).locale}`, row.id);
    for (const row of snapshot.buildLocales) journal?.observe(`build-locale:${buildID}:${attrs(row).locale}`, row.id);
    if (snapshot.groupBuilds.some(row => row.id === buildID)) journal?.observe(`associate:${snapshot.group.id}:${buildID}`, buildID);
    const desired = expectedApp(snapshot, content);
    const candidate = contact ?? storedContact(snapshot.review);
    ensure(validContact(candidate), 'BLOCKED_INPUT', 'Real review contact first name, last name, email and international phone are required privately');
    report.review_contact_available = true;
    await urlCheck();
    report.public_metadata_urls_verified = true;
    ensure(snapshot.groups.some(group => attrs(group).isInternalGroup === true), 'BLOCKED_GROUP', 'Apple requires an internal group before an external group');
    const mutation = async (path, body) => {
      await api(path, 'PATCH', body);
      report.mutations.push({ method: 'PATCH', resource_path: path, response_observed: true });
    };
    const post = async (key, path, body) => {
      ensure(journal, 'BLOCKED_STATE', 'Mutation requires a persistent single-operator journal');
      const result = await journal.postOnce(key, 'POST', path, body, api);
      report.mutations.push({ method: 'POST', resource_path: path, response_observed: true, resource_id: result.data?.id ?? null });
      return result;
    };
    if (action === 'preflight' || !apply) {
      if (action === 'submit' || action === 'enable-public-link') {
        ensure(staged(snapshot, content), 'BLOCKED_METADATA', 'Actual Apple metadata, contact, whatsNew and exact group/build association must be staged first');
      }
      if (action === 'submit' && snapshot.submission) {
        ensure(['WAITING_FOR_REVIEW', 'IN_REVIEW', 'APPROVED'].includes(attrs(snapshot.submission).betaReviewState),
          'BLOCKED_REVIEW', 'Existing rejected or unknown submission needs explicit coordinator review');
      }
      if (action === 'submit' && !snapshot.submission) {
        ensure(attrs(snapshot.detail).externalBuildState === 'READY_FOR_BETA_SUBMISSION', 'BLOCKED_REVIEW', 'Exact build is not ready for external beta submission');
      }
      report.state = 'PREFLIGHT_READY';
      report.metadata_staged = !!staged(snapshot, content);
      report.apple_external_approval_observed = approved(snapshot);
      report.proposed_action = action === 'preflight' ? 'stage' : action;
      report.proposed_metadata = { locale: 'en-US', description: content.description, whatsNew: content.whatsNew,
        review_notes_present: true, marketing_url: MARKETING_URL, privacy_url: PRIVACY_URL };
      report.proposed_group = { name: GROUP_NAME, isInternalGroup: false, publicLinkLimit: CAP,
        publicLinkLimitEnabled: true, publicLinkEnabled: false, hasAccessToAllBuilds: false };
      if (action === 'enable-public-link') ensure(approved(snapshot), 'BLOCKED_REVIEW', 'Exact build external approval has not been observed');
      return report;
    }
    if (action === 'stage') {
      ensure(attrs(snapshot.group).publicLinkEnabled !== true, 'BLOCKED_GROUP', 'Target group is already public; review its live cohort before restaging');
      ensure(!snapshot.submission, 'BLOCKED_REVIEW', 'Review submission already exists; preserve its metadata and inspect review state');
      if (attrs(snapshot.detail).autoNotifyEnabled !== false) {
        await mutation(`buildBetaDetails/${id(snapshot.detail.id)}`, resource('buildBetaDetails', snapshot.detail.id, { autoNotifyEnabled: false }));
      }
      const appLocale = snapshot.appLocales.find(row => attrs(row).locale === 'en-US');
      if (appLocale) {
        if (!same(attrs(appLocale), desired)) await mutation(`betaAppLocalizations/${id(appLocale.id)}`, resource('betaAppLocalizations', appLocale.id, desired));
      } else {
        await post(`app-locale:${APP}:en-US`, 'betaAppLocalizations', resource('betaAppLocalizations', null,
          { ...desired, locale: 'en-US' }, { app: relationship('apps', APP) }));
      }
      const reviewAttributes = contactAttributes(candidate, content);
      if (!same(attrs(snapshot.review), reviewAttributes)) {
        await mutation(`betaAppReviewDetails/${id(snapshot.review.id)}`, resource('betaAppReviewDetails', snapshot.review.id, reviewAttributes));
      }
      const buildLocale = snapshot.buildLocales.find(row => attrs(row).locale === 'en-US');
      if (buildLocale) {
        if (attrs(buildLocale).whatsNew !== content.whatsNew) await mutation(`betaBuildLocalizations/${id(buildLocale.id)}`,
          resource('betaBuildLocalizations', buildLocale.id, { whatsNew: content.whatsNew }));
      } else {
        await post(`build-locale:${buildID}:en-US`, 'betaBuildLocalizations', resource('betaBuildLocalizations', null,
          { locale: 'en-US', whatsNew: content.whatsNew }, { build: relationship('builds', buildID) }));
      }
      let group = snapshot.group;
      const groupAttributes = { publicLinkEnabled: false, publicLinkLimitEnabled: true, publicLinkLimit: CAP, feedbackEnabled: true };
      if (!group) {
        group = (await post(groupKey, 'betaGroups', resource('betaGroups', null,
          { ...groupAttributes, name: GROUP_NAME, isInternalGroup: false, hasAccessToAllBuilds: false }, { app: relationship('apps', APP) }))).data;
        ensure(group?.id, 'BLOCKED_RESPONSE', 'Group creation response did not provide an ID; reconcile without creating another group');
      } else if (!same(attrs(group), groupAttributes)) {
        await mutation(`betaGroups/${id(group.id)}`, resource('betaGroups', group.id, groupAttributes));
      }
      if (!snapshot.groupBuilds.some(row => row.id === buildID)) {
        await post(`associate:${group.id}:${buildID}`, `betaGroups/${id(group.id)}/relationships/builds`, { data: [{ type: 'builds', id: buildID }] });
      }
      snapshot = await inspectBound();
      ensure(staged(snapshot, content) && attrs(snapshot.group).publicLinkEnabled === false,
        'BLOCKED_READBACK', 'Staging response did not produce the expected private group and metadata readback');
      report.state = 'STAGED_PRIVATE';
    } else if (action === 'submit') {
      ensure(staged(snapshot, content), 'BLOCKED_METADATA', 'Actual Apple metadata, contact, whatsNew and exact group/build association must be staged first');
      ensure(attrs(snapshot.group).publicLinkEnabled === false || approved(snapshot), 'BLOCKED_GROUP', 'An unapproved group must not expose a public link');
      if (snapshot.submission) {
        ensure(['WAITING_FOR_REVIEW', 'IN_REVIEW', 'APPROVED'].includes(attrs(snapshot.submission).betaReviewState),
          'BLOCKED_REVIEW', 'Existing rejected or unknown submission needs explicit coordinator review; no resubmission');
      } else {
        ensure(attrs(snapshot.detail).externalBuildState === 'READY_FOR_BETA_SUBMISSION', 'BLOCKED_REVIEW', 'Exact build is not ready for external beta submission');
        const submitted = (await post(submitKey, 'betaAppReviewSubmissions', resource('betaAppReviewSubmissions', null, null,
          { build: relationship('builds', buildID) }))).data;
        ensure(submitted?.id, 'BLOCKED_RESPONSE', 'Submission response lacked an ID; reconcile without submitting again');
        report.review_submission_id = submitted.id;
        snapshot = await inspectBound();
        ensure(snapshot.submission?.id === submitted.id, 'BLOCKED_READBACK', 'Submission relationship readback is not yet visible; preserve the journal and reconcile');
      }
      report.state = approved(snapshot) ? 'EXTERNAL_APPROVED' : 'EXTERNAL_REVIEW_PENDING';
    } else {
      // URL checks and earlier reads may take time; refresh exact eligibility/approval before enabling.
      snapshot = await inspectBound();
      ensure(staged(snapshot, content), 'BLOCKED_METADATA', 'Exact staged group, metadata and build are required');
      ensure(approved(snapshot), 'BLOCKED_REVIEW', 'Exact build needs an APPROVED review submission and external BETA_APPROVED or IN_BETA_TESTING state');
      if (attrs(snapshot.group).publicLinkEnabled !== true) await mutation(`betaGroups/${id(snapshot.group.id)}`,
        resource('betaGroups', snapshot.group.id, { publicLinkEnabled: true, publicLinkLimitEnabled: true, publicLinkLimit: CAP }));
      snapshot = await inspectBound();
      ensure(staged(snapshot, content) && approved(snapshot) && attrs(snapshot.group).publicLinkEnabled === true
        && attrs(snapshot.group).publicLinkLimitEnabled === true && attrs(snapshot.group).publicLinkLimit === CAP
        && /^https:\/\/testflight\.apple\.com\/join\/[A-Za-z0-9]+$/.test(attrs(snapshot.group).publicLink ?? ''),
        'BLOCKED_READBACK', 'Exact staged metadata, build membership, approval and enabled capped public URL were not observed together in readback');
      report.state = 'PUBLIC_LINK_ENABLED';
      report.public_url = attrs(snapshot.group).publicLink;
      report.external_testing_active = attrs(snapshot.detail).externalBuildState === 'IN_BETA_TESTING';
    }
    const mutations = report.mutations;
    const state = report.state;
    report = { ...report, ...sanitized(snapshot, action, apply), mutations, state };
    report.metadata_staged = !!staged(snapshot, content);
    report.apple_external_approval_observed = approved(snapshot);
    if (snapshot.submission) journal.observe(submitKey, snapshot.submission.id);
    if (snapshot.group) journal.observe(groupKey, snapshot.group.id);
    return report;
  } catch (error) {
    report.state = error instanceof Blocked ? error.code : 'BLOCKED_ERROR';
    report.blockers.push({ code: report.state, reason: error instanceof Blocked ? error.message : 'Unexpected local error; inspect protected operator logs without exposing credentials or contact values' });
    return report;
  }
}

export function privateJSON(path, contactFile = false) {
  let descriptor;
  try {
    const absolute = resolve(path);
    if (contactFile) {
      const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
      const inside = relative(root, absolute);
      ensure(inside === '..' || inside.startsWith(`..${sep}`) || isAbsolute(inside),
        'BLOCKED_INPUT', 'Keep the private review contact file outside the repository');
    }
    // O_NOFOLLOW rejects a final-component symlink where supported. O_NONBLOCK
    // prevents a FIFO from hanging during open, before the regular-file check.
    descriptor = openSync(absolute, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0));
    const info = fstatSync(descriptor);
    ensure(info.isFile(), 'BLOCKED_INPUT', 'Input JSON must be a regular file');
    if (contactFile && process.platform !== 'win32') {
      ensure((info.mode & 0o077) === 0, 'BLOCKED_INPUT', 'Private contact file must not grant group/other access');
    }
    const limit = 20000;
    ensure(info.size <= limit, 'BLOCKED_INPUT', 'Private input file exceeds the size limit');
    // The opened file can grow after fstat. Read at most limit+1 bytes from the
    // same descriptor and reject overflow before decoding or parsing any values.
    const bytes = Buffer.alloc(limit + 1);
    let length = 0;
    while (length < bytes.length) {
      const count = readSync(descriptor, bytes, length, bytes.length - length, null);
      if (count === 0) break;
      length += count;
    }
    ensure(length <= limit, 'BLOCKED_INPUT', 'Private input file exceeds the size limit');
    return JSON.parse(bytes.subarray(0, length).toString('utf8'));
  } catch (error) {
    if (error instanceof Blocked) throw error;
    throw new Blocked('BLOCKED_INPUT', 'Input JSON could not be read; values are not printed');
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export async function main(argv = process.argv.slice(2)) {
  let journal;
  let options = { action: 'preflight', apply: false, stateDir: 'build/release/public-beta' };
  try {
    ensure(Number(process.versions.node.split('.')[0]) >= 22, 'BLOCKED_RUNTIME', 'Node 22 or later is required');
    if (argv.includes('--help')) {
      console.log('public-beta.mjs [preflight|stage|submit|enable-public-link] --build-id UUID --source-sha FULL_SHA --compiled-identity-receipt PATH --release-receipt PATH --processing-receipt PATH [--apply] [--contact-file PRIVATE_JSON] [--content-file REVIEWED_JSON] [--state-dir PRIVATE_DIRECTORY]');
      return 0;
    }
    if (argv[0] && !argv[0].startsWith('--')) options.action = argv.shift();
    for (let index = 0; index < argv.length; index += 1) {
      const flag = argv[index];
      if (flag === '--apply') { options.apply = true; continue; }
      const keys = { '--build-id': 'buildID', '--source-sha': 'sourceSHA', '--compiled-identity-receipt': 'identityPath',
        '--release-receipt': 'releasePath', '--processing-receipt': 'processingPath',
        '--contact-file': 'contactFile', '--content-file': 'contentFile', '--state-dir': 'stateDir' };
      ensure(keys[flag] && argv[index + 1] && !argv[index + 1].startsWith('--'), 'BLOCKED_INPUT', 'Unknown option or missing option value');
      options[keys[flag]] = argv[++index];
    }
    ensure(UUID.test(options.buildID ?? ''), 'BLOCKED_INPUT', 'An exact Apple build UUID is required');
    ensure(options.identityPath && options.releasePath && options.processingPath,
      'BLOCKED_PROMOTION_EVIDENCE', 'Paths to compiled identity, accepted release and Apple processing receipts are required');
    const evidence = { sourceSHA: options.sourceSHA, compiledIdentity: privateJSON(options.identityPath),
      releaseReceipt: privateJSON(options.releasePath), processingReceipt: privateJSON(options.processingPath) };
    verifyPromotionEvidence(evidence, options.buildID);
    const api = protectedClient();
    const contact = options.contactFile ? privateJSON(options.contactFile, true) : null;
    const content = options.contentFile ? privateJSON(options.contentFile) : DEFAULT_CONTENT;
    journal = new Journal(options.stateDir);
    const report = await execute({ ...options, ...evidence, api, journal, contact, content });
    writeAtomic(resolve(options.stateDir, `receipt-${options.buildID}.json`), report);
    console.log(JSON.stringify(report, null, 2));
    return report.blockers.length ? 2 : 0;
  } catch (error) {
    const report = { state: error instanceof Blocked ? error.code : 'BLOCKED_ERROR', action: options.action,
      apply_requested: options.apply, app_id: APP, version: VERSION, blockers: [{ reason: error instanceof Blocked ? error.message : 'Local initialization failed; no secret values are printed' }] };
    console.log(JSON.stringify(report, null, 2));
    return 2;
  } finally { journal?.close(); }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) process.exitCode = await main();
