<?php

declare(strict_types=1);

use pocketmine\nethernet\signaling\Signal;
use pocketmine\nethernet\signaling\SignalingException;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 2) {
    fwrite(STDERR, "Usage: php tools/generate_signaling_fixtures.php NETHERNET_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
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
    if (!in_array($relative, ['signaling\\Signal', 'signaling\\SignalType', 'signaling\\SignalingException', 'NetherNetException'], true)) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    require $directory . '/src/' . str_replace('\\', '/', $relative) . '.php';
});
$cases = [
    ['offer', 'CONNECTREQUEST 42 synthetic-offer'],
    ['answer', 'CONNECTRESPONSE 7 synthetic-answer'],
    ['candidate', 'CANDIDATEADD 12 synthetic-candidate'],
    ['error', 'CONNECTERROR 9 3'],
    ['empty_data', 'CONNECTREQUEST 0 '],
    ['leading_zeroes', 'CONNECTREQUEST 00042 x'],
    ['zeroes_only', 'CONNECTREQUEST 00000 x'],
    ['decimal_suffix', 'CONNECTREQUEST 42suffix x'],
    ['zero_suffix', 'CONNECTREQUEST 000suffix x'],
    ['maximum', 'CONNECTREQUEST 18446744073709551615 x'],
    ['maximum_suffix', 'CONNECTREQUEST 18446744073709551615tail x'],
    ['long_zero_prefix', 'CONNECTREQUEST ' . str_repeat('0', 128) . '42 x'],
    ['opaque_binary', "CONNECTREQUEST 8 \x00\xff\x80"],
    ['spaces_in_data', 'CONNECTREQUEST 8  a b  '],
    ['newline_data', "CONNECTRESPONSE 8 x\r\ny\n"],
    ['opaque_error', 'CONNECTERROR 8 not-a-number'],
    ['missing_fields', 'CONNECTREQUEST'],
    ['missing_data_separator', 'CONNECTREQUEST 8'],
    ['tabs', "CONNECTREQUEST\t8\tx"],
    ['empty_id', 'CONNECTREQUEST  x'],
    ['negative_id', 'CONNECTREQUEST -1 x'],
    ['plus_id', 'CONNECTREQUEST +1 x'],
    ['nonnumeric_id', 'CONNECTREQUEST x42 x'],
    ['overflow', 'CONNECTREQUEST 18446744073709551616 x'],
    ['long_overflow', 'CONNECTREQUEST ' . str_repeat('9', 128) . ' x'],
    ['lowercase_kind', 'connectrequest 8 x'],
    ['unknown_kind', 'UNKNOWN 8 x'],
    ['leading_space', ' CONNECTREQUEST 8 x'],
    ['tab_suffix', "CONNECTREQUEST 8\ttail x"],
    ['embedded_null_id_suffix', "CONNECTREQUEST 8\x00tail x"],
];
$results = [];
foreach ($cases as [$name, $wire]) {
    $entry = ['name' => $name, 'wire_hex' => bin2hex($wire)];
    try {
        $signal = Signal::parse($wire);
        $entry['kind'] = $signal->type->value;
        $entry['connection_id'] = $signal->connectionId;
        $entry['data_hex'] = bin2hex($signal->data);
        $entry['encoded_hex'] = bin2hex($signal->toString());
    } catch (SignalingException) {
        $entry['error'] = true;
    }
    $results[] = $entry;
}
$oracle = ['repository' => 'https://github.com/axolotl-pm/nethernet', 'branch' => 'master',
    'revision' => $revision, 'license' => 'LGPL-3.0-or-later'];
$json = json_encode(['oracle' => $oracle, 'cases' => $results], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
$output = __DIR__ . '/../src/transport/fixtures';
file_put_contents($output . '/signaling.json', $json);
$manifest = ['schema' => 1, 'oracle' => $oracle, 'php' => PHP_VERSION,
    'generator_sha256' => hash_file('sha256', __FILE__), 'cases' => count($results),
    'bytes' => strlen($json), 'sha256' => hash('sha256', $json)];
file_put_contents($output . '/signaling-manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
echo 'Generated ' . count($results) . " signaling oracle cases\n";
