<?php

declare(strict_types=1);

use pocketmine\nethernet\crypto\Base64Url;
use pocketmine\nethernet\identity\IdentityAssertion;
use pocketmine\nethernet\identity\IdentityException;
use pocketmine\nethernet\identity\JsonWebSignature;
use pocketmine\nethernet\identity\JsonWebToken;
use pocketmine\nethernet\identity\PublicKey;
use pocketmine\nethernet\identity\ServerIdentity;
use pocketmine\nethernet\sdp\Fingerprint;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 2) {
    fwrite(STDERR, "Usage: php tools/generate_identity_fixtures.php NETHERNET_DIR\nRequires 64-bit PHP 8.4, OpenSSL and Git\n");
    exit(2);
}
$directory = $argv[1];
$revision = '6ecacdaed3b0605a6a523235e5536f9c09ea56fd';
function gitOutput(string $directory, array $arguments): string {
    $process = proc_open(['git', '-C', $directory, ...$arguments], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('Cannot start Git');
    }
    $output = stream_get_contents($pipes[1]);
    $error = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    if (proc_close($process) !== 0) {
        throw new RuntimeException('Git verification failed: ' . $error);
    }
    return trim($output);
}
if (gitOutput($directory, ['rev-parse', 'HEAD']) !== $revision || gitOutput($directory, ['status', '--porcelain', '--untracked-files=all']) !== '') {
    throw new RuntimeException('NetherNet must be clean at the recorded default-branch revision');
}
spl_autoload_register(static function (string $class) use ($directory): void {
    $prefix = 'pocketmine\\nethernet\\';
    if (!str_starts_with($class, $prefix)) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    $relative = substr($class, strlen($prefix));
    if (preg_match('/^(?:(?:identity|crypto)\\\\[A-Za-z][A-Za-z0-9]*|sdp\\\\(?:Fingerprint|SdpException)|NetherNetException)$/D', $relative) !== 1) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    require $directory . '/src/' . str_replace('\\', '/', $relative) . '.php';
});

// Ephemeral synthetic keys exist only in this process. No private key is exported.
// Regeneration intentionally produces fresh public keys and randomized signatures.
$identity = ServerIdentity::generate();
$other = ServerIdentity::generate();
$public = $identity->getPublicKey();
$details = openssl_pkey_get_details($identity->getPrivateKey());
if (!is_array($details) || !isset($details['ec']['x'], $details['ec']['y'])) {
    throw new RuntimeException('Cannot read synthetic public coordinates');
}
$x = str_pad($details['ec']['x'], 48, "\x00", STR_PAD_LEFT);
$y = str_pad($details['ec']['y'], 48, "\x00", STR_PAD_LEFT);
$jwk = ['kty' => 'EC', 'crv' => 'P-384', 'x' => Base64Url::encode($x), 'y' => Base64Url::encode($y)];
$compressed = "\x30\x46\x30\x10\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x05\x2b\x81\x04\x00\x22\x03\x32\x00" . chr(2 + (ord($y[47]) & 1)) . $x;
$keyCases = [];
foreach ([
    ['spki', $public->toBase64Der()], ['jwk', $jwk], ['compressed_spki', base64_encode($compressed)],
    ['null', null], ['number', 7], ['empty', ''], ['invalid_base64', '!!!'], ['invalid_der', 'AAAA'],
    ['wrong_curve', array_replace($jwk, ['crv' => 'P-256'])], ['wrong_type', array_replace($jwk, ['kty' => 'RSA'])],
    ['short_coordinate', array_replace($jwk, ['x' => 'AA'])],
    ['off_curve', array_replace($jwk, ['x' => Base64Url::encode(str_repeat("\x00", 48)), 'y' => Base64Url::encode(str_repeat("\x00", 48))])],
] as [$name, $claim]) {
    $case = ['name' => $name, 'claim' => $claim];
    try {
        $key = PublicKey::fromClaim($claim);
        $case['der_hex'] = bin2hex(base64_decode($key->toBase64Der(), true));
        $case['digest_hex'] = bin2hex($key->getDigest());
    } catch (IdentityException) {
        $case['error'] = true;
    }
    $keyCases[] = $case;
}

$fingerprint = Fingerprint::parse('sha-256 ' . implode(':', array_map(static fn(int $value): string => sprintf('%02X', $value), range(0, 31))));
$payload = $fingerprint->toCanonicalPayload();
$token = JsonWebToken::create(['x5u' => $public->toBase64Der()], ['cpk' => $public->toBase64Der(), 'iat' => 1000, 'exp' => 1060], $identity);
$jwkToken = JsonWebToken::create([], ['cpk' => $jwk, 'iat' => 1000, 'exp' => 1060], $identity);
$proof = JsonWebSignature::signDetached($payload, $identity);
$encoded = IdentityAssertion::create('synthetic.example', $token, $proof)->encode();
$allPayload = json_encode(['fingerprint' => [
    ['algorithm' => 'sha-256', 'digest' => $fingerprint->getDigest()],
    ['algorithm' => 'SHA-256', 'digest' => $fingerprint->getDigest()],
]], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
function mutateEnvelope(string $encoded, callable $mutate): string {
    $value = json_decode(base64_decode($encoded, true), true, flags: JSON_THROW_ON_ERROR);
    $mutate($value);
    return base64_encode(json_encode($value, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
}
function mutateInner(array &$value, callable $mutate): void {
    $inner = json_decode($value['assertion'], true, flags: JSON_THROW_ON_ERROR);
    $mutate($inner);
    $value['assertion'] = json_encode($inner, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
}
$rawCases = [
    ['spki', $encoded, $payload],
    ['jwk', IdentityAssertion::create('synthetic.example', $jwkToken, $proof)->encode(), $payload],
    ['all_fingerprints', IdentityAssertion::create('synthetic.example', $jwkToken, JsonWebSignature::signDetached($allPayload, $identity))->encode(), $allPayload],
    ['wrong_payload', $encoded, str_replace('00:01', 'FF:01', $payload)],
    ['wrong_key', IdentityAssertion::create('synthetic.example', $token, JsonWebSignature::signDetached($payload, $other))->encode(), $payload],
    ['zero_signature', IdentityAssertion::create('synthetic.example', $token, Base64Url::encode('{"alg":"ES384"}') . '..' . Base64Url::encode(str_repeat("\x00", 96)))->encode(), $payload],
    ['empty_attribute', '', $payload], ['invalid_base64', '!!!', $payload], ['invalid_json', base64_encode('{'), $payload],
    ['array_envelope', base64_encode('[1]'), $payload], ['missing_fields', base64_encode('{}'), $payload],
    ['nested_assertion', mutateEnvelope($encoded, static function (array &$value): void { $value['assertion'] = ['token' => 'wrong']; }), $payload],
    ['empty_domain', mutateEnvelope($encoded, static function (array &$value): void { $value['idp']['domain'] = ''; }), $payload],
    ['wrong_protocol', mutateEnvelope($encoded, static function (array &$value): void { $value['idp']['protocol'] = 'other'; }), $payload],
    ['missing_token', mutateEnvelope($encoded, static function (array &$value): void { mutateInner($value, static function (array &$inner): void { unset($inner['token']); }); }), $payload],
    ['extra_token_segment', mutateEnvelope($encoded, static function (array &$value): void { mutateInner($value, static function (array &$inner): void { $inner['token'] .= '.extra'; }); }), $payload],
    ['malformed_proof', IdentityAssertion::create('synthetic.example', $token, 'bad')->encode(), $payload],
    ['carried_payload', IdentityAssertion::create('synthetic.example', $token, str_replace('..', '.eA.', $proof))->encode(), $payload],
    ['wrong_proof_algorithm', IdentityAssertion::create('synthetic.example', $token, Base64Url::encode('{"alg":"HS256"}') . '..' . explode('.', $proof)[2])->encode(), $payload],
    ['short_proof_signature', IdentityAssertion::create('synthetic.example', $token, explode('.', $proof)[0] . '..AA')->encode(), $payload],
];
foreach ([0, 383, 384, 385, 768, 769] as $length) {
    $testPayload = str_repeat('x', $length);
    $rawCases[] = ['crypto_payload_' . $length, IdentityAssertion::create('synthetic.example', $token, JsonWebSignature::signDetached($testPayload, $identity))->encode(), $testPayload];
}
$assertions = [];
foreach ($rawCases as [$name, $input, $testPayload]) {
    $case = ['name' => $name, 'attribute' => $input, 'payload_hex' => bin2hex($testPayload)];
    try {
        $parsed = IdentityAssertion::parse($input);
        $case['domain'] = $parsed->getDomain();
        $case['token'] = $parsed->getToken()->toString();
        $case['key_digest_hex'] = bin2hex($parsed->getToken()->getPublicKey()->getDigest());
        $case['token_signed'] = $parsed->getToken()->isSignedBy($public);
        $inner = json_decode(json_decode(base64_decode($input, true), true, flags: JSON_THROW_ON_ERROR)['assertion'], true, flags: JSON_THROW_ON_ERROR);
        try {
            $case['proof_valid'] = JsonWebSignature::verifyDetached($inner['fingerprints'], $testPayload, $parsed->getToken()->getPublicKey());
        } catch (IdentityException) {
            $case['proof_error'] = true;
        }
    } catch (IdentityException) {
        $case['parse_error'] = true;
    }
    $assertions[] = $case;
}
$timestamps = [];
foreach ([
    ['missing', [], 1000, 60], ['null', ['exp' => null], 1000, 60],
    ['expiry_before', ['exp' => 1060], 1119, 60], ['expiry_at', ['exp' => 1060], 1120, 60],
    ['not_before_before', ['nbf' => 1000], 939, 60], ['not_before_at', ['nbf' => 1000], 940, 60],
    ['issued_before', ['iat' => 1000], 939, 60], ['issued_at', ['iat' => 1000], 940, 60],
    ['no_leeway_valid', ['exp' => 1000], 999, 0], ['no_leeway_expired', ['exp' => 1000], 1000, 0],
    ['fractional_expiry', ['exp' => 1000.9], 1000, 0], ['fractional_not_before', ['nbf' => 1000.9], 1000, 0],
    ['invalid_string', ['exp' => '1000'], 1000, 60], ['invalid_bool', ['iat' => true], 1000, 60],
    ['negative_fraction', ['nbf' => -1000.9], -1000, 0],
] as [$name, $claims, $now, $leeway]) {
    $currentToken = JsonWebToken::create([], ['cpk' => $jwk] + $claims, $identity);
    $case = ['name' => $name, 'attribute' => IdentityAssertion::create('synthetic.example', $currentToken, $proof)->encode(), 'now' => $now, 'leeway' => $leeway];
    try {
        $currentToken->checkTimestamps($now, $leeway);
        $case['valid'] = true;
    } catch (IdentityException) {
        $case['valid'] = false;
    }
    $timestamps[] = $case;
}
$oracle = ['repository' => 'https://github.com/axolotl-pm/nethernet', 'branch' => 'master', 'revision' => $revision, 'license' => 'LGPL-3.0-or-later'];
$counts = ['keys' => count($keyCases), 'assertions' => count($assertions), 'timestamps' => count($timestamps)];
$json = json_encode(['oracle' => $oracle, 'keys' => $keyCases, 'assertions' => $assertions, 'timestamps' => $timestamps], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
$output = __DIR__ . '/../src/transport/fixtures';
file_put_contents($output . '/identity.json', $json);
$manifest = ['schema' => 1, 'oracle' => $oracle, 'php' => PHP_VERSION, 'generator_sha256' => hash_file('sha256', __FILE__), 'cases' => $counts, 'bytes' => strlen($json), 'sha256' => hash('sha256', $json)];
file_put_contents($output . '/identity-manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
echo json_encode($counts, JSON_THROW_ON_ERROR) . "\n";
