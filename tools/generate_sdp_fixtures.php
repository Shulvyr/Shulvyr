<?php

declare(strict_types=1);

use pocketmine\nethernet\sdp\Fingerprint;
use pocketmine\nethernet\sdp\SessionDescription;
use pocketmine\nethernet\sdp\SdpException;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 2) {
    fwrite(STDERR, "Usage: php tools/generate_sdp_fixtures.php NETHERNET_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
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
    if (!in_array($relative, ['sdp\\Fingerprint', 'sdp\\SessionDescription', 'sdp\\SdpException', 'NetherNetException'], true)) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    require $directory . '/src/' . str_replace('\\', '/', $relative) . '.php';
});

function fingerprintResult(Fingerprint $value): array {
    return ['algorithm' => $value->getAlgorithm(), 'digest_hex' => bin2hex($value->getDigest()),
        'attribute_hex' => bin2hex($value->toAttributeValue()), 'canonical_hex' => bin2hex($value->toCanonicalPayload())];
}

// All descriptions and ICE values below are synthetic. They are not captures.
$fp = 'sha-256 ' . implode(':', array_fill(0, 32, 'AB'));
$head = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=synthetic\r\nt=0 0\r\na=identity:synthetic-assertion\r\n";
$media = "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 127.0.0.1\r\na=ice-ufrag:synthetic\r\na=ice-pwd:synthetic-not-a-credential\r\na=setup:actpass\r\na=max-message-size:262144\r\na=fingerprint:$fp\r\n";
$candidate1 = '1 1 UDP 1 127.0.0.1 12345 typ host';
$candidate2 = '2 1 UDP 1 127.0.0.1 12346 typ host';
$candidates = "a=candidate:$candidate1\r\na=candidate:$candidate2\r\na=end-of-candidates\r\n";
$base = $head . $media . $candidates;
$noFingerprint = str_replace("a=fingerprint:$fp\r\n", '', $base);
$fallback = str_replace("m=application", "a=fingerprint:$fp\r\nm=application", $noFingerprint);
$withoutCandidates = $head . $media;
$cases = [
    ['crlf', $base],
    ['lf', str_replace("\r\n", "\n", $base)],
    ['bare_cr', str_replace("\r\n", "\r", $base)],
    ['mixed_empty_lines', "\r\n\n" . str_replace("s=synthetic\r\n", "s=synthetic\r\n\r\n", $base) . "\r"],
    ['no_final_separator', substr($base, 0, -2)],
    ['no_media', "v=0\na=fingerprint:$fp\n"],
    ['multiple_media', $base . "m=audio 9 RTP/AVP 0\r\n"],
    ['session_fingerprint', $fallback],
    ['media_fingerprint_preferred', str_replace('m=application', "a=fingerprint:sha-512 AB\r\nm=application", $base)],
    ['duplicate_media_fingerprint', $base . "a=fingerprint:$fp\r\n"],
    ['duplicate_session_fingerprint', str_replace('m=application', "a=fingerprint:$fp\r\nm=application", $fallback)],
    ['missing_fingerprint', $noFingerprint],
    ['missing_ufrag', str_replace("a=ice-ufrag:synthetic\r\n", '', $base)],
    ['empty_ice_values', str_replace(['a=ice-ufrag:synthetic', 'a=ice-pwd:synthetic-not-a-credential', 'a=setup:actpass'], ['a=ice-ufrag:', 'a=ice-pwd:', 'a=setup:'], $base)],
    ['missing_maximum', str_replace("a=max-message-size:262144\r\n", '', $base)],
    ['duplicate_maximum', $base . "a=max-message-size:64\r\n"],
    ['maximum_zero', str_replace('max-message-size:262144', 'max-message-size:0', $base)],
    ['maximum_one', str_replace('max-message-size:262144', 'max-message-size:1', $base)],
    ['maximum_two', str_replace('max-message-size:262144', 'max-message-size:2', $base)],
    ['maximum_u32', str_replace('max-message-size:262144', 'max-message-size:4294967295', $base)],
    ['maximum_overflow', str_replace('max-message-size:262144', 'max-message-size:4294967296', $base)],
    ['maximum_leading_zeroes', str_replace('max-message-size:262144', 'max-message-size:0000262144', $base)],
    ['maximum_signed', str_replace('max-message-size:262144', 'max-message-size:+64', $base)],
    ['maximum_suffix', str_replace('max-message-size:262144', 'max-message-size:64tail', $base)],
    ['session_only_ice', $head . "a=ice-ufrag:synthetic\r\na=ice-pwd:synthetic\r\na=setup:actpass\r\nm=application\r\na=max-message-size:64\r\na=fingerprint:$fp\r\n"],
    ['unknown_lines', "x=opaque\r\n" . $base . "a=unknown:value\r\n"],
    ['first_session_identity', str_replace('m=application', "a=identity:second\r\nm=application", $base) . "a=identity:media-only\r\n"],
    ['only_identity', 'a=identity:synthetic'],
    ['empty', "\r\n\n\r"],
    ['line_limit', str_repeat("x=0\n", 1024)],
    ['line_overflow', str_repeat("x=0\n", 1025)],
    ['missing_setup', str_replace("a=setup:actpass\r\n", '', $base)],
    ['bare_attribute', str_replace('a=ice-ufrag:synthetic', 'a=ice-ufrag', $base)],
    ['empty_maximum', str_replace('max-message-size:262144', 'max-message-size:', $base)],
    ['whitespace_line', '   '],
    ['opaque_null', str_replace('s=synthetic', "s=synthetic\x00", $base)],
    ['leading_space_media', str_replace('m=application', ' m=application', $base)],
    ['session_candidate', "a=candidate:$candidate2\r\n" . $base],
    ['empty_session_identity', str_replace('identity:synthetic-assertion', 'identity:', $base)],
    ['only_media_identity', str_replace("a=identity:synthetic-assertion\r\n", '', $base) . "a=identity:media-only\r\n"],
    ['duplicate_ice_attribute', $base . "a=ice-ufrag:second-synthetic\r\n"],
    ['only_session_maximum', str_replace('m=application', "a=max-message-size:64\r\nm=application", str_replace("a=max-message-size:262144\r\n", '', $base))],
];
$descriptions = [];
foreach ($cases as [$name, $input]) {
    $entry = ['name' => $name, 'input_hex' => bin2hex($input)];
    try {
        $description = SessionDescription::parse($input);
        $entry['normalized_hex'] = bin2hex($description->toString());
        $entry['line_count'] = count($description->getLines());
        $entry['identity_hex'] = $description->getIdentity() === null ? null : bin2hex($description->getIdentity());
        $entry['candidates'] = $description->countCandidates();
        $entry['session_ufrag'] = array_map(bin2hex(...), $description->getSessionAttributeValues('ice-ufrag'));
        $entry['media_ufrag'] = array_map(bin2hex(...), $description->getMediaAttributeValues('ice-ufrag'));
        try {
            $description->validate();
            $entry['valid'] = true;
        } catch (SdpException) {
            $entry['valid'] = false;
        }
        try {
            $entry['fingerprint'] = fingerprintResult($description->getFingerprint());
        } catch (SdpException) {
            $entry['fingerprint_error'] = true;
        }
        try {
            $entry['maximum'] = $description->getMaxMessageSize();
        } catch (SdpException) {
            $entry['maximum_error'] = true;
        }
    } catch (SdpException) {
        $entry['parse_error'] = true;
    }
    $descriptions[] = $entry;
}
$cases = [
    ['unchanged', $base, 'none', null],
    ['strip_identity', $base, 'without_identity', null],
    ['replace_identity', $base . "a=identity:media\r\n", 'identity', 'replacement'],
    ['empty_identity', $base, 'identity', ''],
    ['identity_no_media', 'v=0', 'identity', 'replacement'],
    ['strip_to_empty', 'a=identity:synthetic', 'without_identity', null],
    ['strip_candidates', $base, 'without_candidates', null],
    ['connection_addresses', "c=IN IP6 ::1\r\n" . $base, 'without_connection_address', null],
    ['replace_candidates', $base, 'candidates', [$candidate2, $candidate1]],
    ['empty_candidates', $base, 'candidates', []],
    ['candidates_before_end', $withoutCandidates . "a=end-of-candidates\r\na=candidate:$candidate1\r\n", 'candidates', [$candidate2]],
    ['append_candidates', $withoutCandidates, 'candidates', [$candidate1]],
    ['replace_session_candidate', "a=candidate:$candidate1\r\n" . $base, 'candidates', [$candidate2]],
    ['limit_zero', $base, 'candidate_limit', 0],
    ['limit_one', $base, 'candidate_limit', 1],
    ['limit_above_count', $base, 'candidate_limit', 8],
    ['replace_only_identity', 'a=identity:old', 'identity', 'replacement'],
    ['append_without_media', 'v=0', 'candidates', [$candidate1]],
];
$edits = [];
foreach ($cases as [$name, $input, $edit, $value]) {
    $description = SessionDescription::parse($input);
    $result = match ($edit) {
        'none' => $description,
        'without_identity' => $description->withoutIdentity(),
        'without_candidates' => $description->withoutCandidates(),
        'without_connection_address' => $description->withoutConnectionAddress(),
        'candidates' => $description->withCandidates($value),
        'candidate_limit' => $description->withCandidateLimit($value),
        'identity' => $description->withIdentity($value),
    };
    $entry = ['name' => $name, 'input_hex' => bin2hex($input), 'edit' => $edit,
        'output_hex' => bin2hex($result->toString())];
    if ($edit === 'identity') $entry['identity_hex'] = bin2hex($value);
    if ($edit === 'candidates') $entry['candidates_hex'] = array_map(bin2hex(...), $value);
    if ($edit === 'candidate_limit') $entry['limit'] = $value;
    $edits[] = $entry;
}
$fingerprints = [];
$cases = [
    ['certificate', 'sha-256 ' . implode(':', array_map(static fn(int $byte): string => strtoupper(bin2hex(chr($byte))), range(0, 31)))],
    ['case', 'SHA-256 ab:Cd'], ['lowercase', 'sha-256 aa:bb'],
    ['short', 'sha-256 AB'], ['empty_digest', 'sha-256 '], ['algorithm', 'sha-512 AB'],
    ['no_separator', 'sha-256'], ['extra_space', 'sha-256  AB'], ['tab', "sha-256\tAB"],
    ['odd_hex', 'sha-256 A'], ['missing_colon', 'sha-256 ABCD'], ['trailing_colon', 'sha-256 AB:'],
    ['leading_colon', 'sha-256 :AB'], ['nonhex', 'sha-256 AG'], ['final_lf', "sha-256 AB\n"],
    ['final_cr', "sha-256 AB\r"], ['two_lf', "sha-256 AB\n\n"],
];
foreach ($cases as [$name, $input]) {
    $entry = ['name' => $name, 'input_hex' => bin2hex($input)];
    try {
        $entry['result'] = fingerprintResult(Fingerprint::parse($input));
    } catch (SdpException) {
        $entry['error'] = true;
    }
    $fingerprints[] = $entry;
}
$oracle = ['repository' => 'https://github.com/axolotl-pm/nethernet', 'branch' => 'master',
    'revision' => $revision, 'license' => 'LGPL-3.0-or-later'];
$json = json_encode(['oracle' => $oracle, 'descriptions' => $descriptions, 'edits' => $edits,
    'fingerprints' => $fingerprints], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
$output = __DIR__ . '/../src/transport/fixtures';
file_put_contents($output . '/sdp.json', $json);
$counts = ['descriptions' => count($descriptions), 'edits' => count($edits), 'fingerprints' => count($fingerprints)];
$manifest = ['schema' => 1, 'oracle' => $oracle, 'php' => PHP_VERSION,
    'generator_sha256' => hash_file('sha256', __FILE__), 'cases' => $counts,
    'bytes' => strlen($json), 'sha256' => hash('sha256', $json)];
file_put_contents($output . '/sdp-manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
echo json_encode($counts, JSON_THROW_ON_ERROR) . "\n";
