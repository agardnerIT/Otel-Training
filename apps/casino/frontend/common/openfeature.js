/**
 * OpenFeature initialization with flagd provider and OpenTelemetry integration
 */

const { OpenFeature } = require('@openfeature/js-sdk');
const { FlagdProvider } = require('@openfeature/flagd-provider');
const { trace } = require('@opentelemetry/api');
const { TracingHook } = require('@openfeature/extra');

// Get flagd connection details from environment
const FLAGD_HOST = process.env.FLAGD_HOST || 'localhost';
const FLAGD_PORT = process.env.FLAGD_PORT || 8013;
const FLAGD_TLS = process.env.FLAGD_TLS === 'true';

// Cap how long a single flag lookup may block so a slow/unreachable flagd
// degrades to the flag default instead of stalling the caller (ISI-7828).
const FLAG_EVAL_TIMEOUT_MS = Number(process.env.FLAG_EVAL_TIMEOUT_MS || 1000);
const FLAG_EVAL_TIMEOUT = Symbol('flag-eval-timeout');

let client = null;

/**
 * Initialize OpenFeature with flagd provider and OpenTelemetry integration
 */
function initializeOpenFeature(serviceName = 'vegas-service') {
  if (client) {
    return client;
  }

  try {
    // Create flagd provider
    const provider = new FlagdProvider({
      host: FLAGD_HOST,
      port: FLAGD_PORT,
      tls: FLAGD_TLS,
    });

    // Create OpenFeature client
    OpenFeature.setProvider(provider);

    // Add OpenTelemetry tracing hook
    OpenFeature.addHooks([new TracingHook()]);

    // Create client with service context
    client = OpenFeature.getClient(serviceName, {
      name: serviceName,
    });

    console.log(`✅ OpenFeature initialized for ${serviceName} (flagd: ${FLAGD_HOST}:${FLAGD_PORT})`);
  } catch (error) {
    console.error(`❌ Failed to initialize OpenFeature: ${error.message}`);
    // Return a mock client that always returns default values
    client = {
      getBooleanValue: (key, defaultValue) => defaultValue,
      getStringValue: (key, defaultValue) => defaultValue,
      getNumberValue: (key, defaultValue) => defaultValue,
      getObjectValue: (key, defaultValue) => defaultValue,
    };
  }

  return client;
}

/**
 * Get feature flag value with OpenTelemetry tracing
 */
async function getFeatureFlag(key, defaultValue, context = {}) {
  if (!client) {
    return defaultValue;
  }

  const tracer = trace.getTracer('openfeature');
  const span = tracer.startSpan(`feature_flag.${key}`);

  // Resolve the flag against the provider and tag the span with the value.
  const evaluate = async () => {
    span.setAttributes({
      'feature_flag.key': key,
      'feature_flag.provider': 'flagd',
    });
    if (typeof defaultValue === 'boolean') {
      const value = await client.getBooleanValue(key, defaultValue, context);
      span.setAttribute('feature_flag.value', value);
      span.setAttribute('feature_flag.type', 'boolean');
      return value;
    } else if (typeof defaultValue === 'number') {
      const value = await client.getNumberValue(key, defaultValue, context);
      span.setAttribute('feature_flag.value', value);
      span.setAttribute('feature_flag.type', 'number');
      return value;
    } else if (typeof defaultValue === 'string') {
      const value = await client.getStringValue(key, defaultValue, context);
      span.setAttribute('feature_flag.value', value);
      span.setAttribute('feature_flag.type', 'string');
      return value;
    } else {
      const value = await client.getObjectValue(key, defaultValue, context);
      span.setAttribute('feature_flag.type', 'object');
      return value;
    }
  };

  // Race the evaluation against a timeout so a slow flagd cannot block the
  // caller; fall back to the default on timeout (ISI-7828).
  let timer = null;
  const evalPromise = evaluate();
  evalPromise.catch(() => {}); // swallow late rejection if the timeout wins
  const timeoutPromise = new Promise((resolve) => {
    timer = setTimeout(() => resolve(FLAG_EVAL_TIMEOUT), FLAG_EVAL_TIMEOUT_MS);
  });

  try {
    const outcome = await Promise.race([evalPromise, timeoutPromise]);
    if (outcome === FLAG_EVAL_TIMEOUT) {
      span.setAttribute('feature_flag.timeout', true);
      span.setAttribute('feature_flag.value', String(defaultValue));
      console.warn(`[OpenFeature] Flag ${key} evaluation exceeded ${FLAG_EVAL_TIMEOUT_MS}ms, using default: ${defaultValue}`);
      return defaultValue;
    }
    return outcome;
  } catch (error) {
    span.recordException(error);
    span.setAttribute('feature_flag.error', true);
    console.error(`Error getting feature flag ${key}:`, error);
    return defaultValue;
  } finally {
    if (timer) clearTimeout(timer);
    span.end();
  }
}

module.exports = {
  initializeOpenFeature,
  getFeatureFlag,
  OpenFeature,
};

