// T69: CloudFront viewer-request gate for CTA-5007 Common Access Tokens (runtime cloudfront-js-2.0).
// The token arrives in CTA-Common-Access-Token. Its MAC is checked with the HS256 key the associated
// KeyValueStore holds under "k:<KID>"; validateToken() checks nothing else, so iss, exp, nbf, catv
// and catu are checked here (catu: the path component with a prefix match only; anything else is
// refused), then the cti is looked up under "rev:<cti hex>". Each refusal names its reason in
// x-t69-deny, which is how the probes tell a revocation from any other refusal.
import cf from 'cloudfront';

const kvs = cf.kvs();
const KID = 't69k1';
const ISS = 't69';

function deny(code, why) {
    return {
        statusCode: code,
        statusDescription: why,
        headers: { 'x-t69-deny': { value: why }, 'cache-control': { value: 'no-store' } },
    };
}

function hex(v) {
    if (typeof v === 'string') return Buffer.from(v, 'binary').toString('hex');
    return Buffer.from(v).toString('hex');
}

async function handler(event) {
    const req = event.request;
    const h = req.headers['cta-common-access-token'];
    if (!h) return deny(401, 'missing');
    let key;
    try {
        key = await kvs.get('k:' + KID);
    } catch (e) {
        return deny(500, 'nokey');
    }
    let tok;
    try {
        tok = cf.cwt.validateToken(Buffer.from(h.value, 'base64url'), { key: Buffer.from(key, 'hex') });
    } catch (e) {
        return deny(401, 'mac');
    }
    const p = tok.payload;
    const now = Math.floor(Date.now() / 1000);
    if (p['1'] !== ISS) return deny(401, 'iss');
    if (typeof p['4'] !== 'number' || p['4'] <= now) return deny(401, 'expired');
    if (p['5'] !== undefined && p['5'] > now) return deny(401, 'nbf');
    if (p['310'] !== undefined && p['310'] !== 1) return deny(401, 'catv');
    const catu = p['312'];
    if (catu !== undefined) {
        for (const comp in catu) {
            if (comp !== '3') return deny(403, 'catu');
            const m = catu[comp];
            for (const t in m) {
                if (t !== '1') return deny(403, 'catu');
                if (!req.uri.startsWith(m[t])) return deny(403, 'uri');
            }
        }
    }
    if (p['7'] === undefined) return deny(401, 'cti');
    let revoked;
    try {
        revoked = await kvs.exists('rev:' + hex(p['7']));
    } catch (e) {
        return deny(500, 'kvs');
    }
    if (revoked) return deny(403, 'revoked');
    return req;
}
