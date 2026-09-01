// A placeholder standing in for the bundle scripts/bundle-worker.mjs produces.
//
// It has to be a real file: the Cloudflare provider reads `content_file` and
// hashes it during plan, so a mocked path that does not exist fails before any
// assertion runs. Nothing here is executed, and nothing asserts on it.
export default { fetch: () => new Response('mock', { status: 200 }) };
