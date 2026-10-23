<?php

declare(strict_types=1);

use pocketmine\nethernet\protocol\framing\Assembler;
use pocketmine\nethernet\protocol\framing\Segmenter;
use pocketmine\nethernet\protocol\framing\FramingException;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 2) {
    fwrite(STDERR, "Usage: php tools/generate_framing_fixtures.php NETHERNET_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
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
    if ($class === 'pocketmine\\nethernet\\NetherNetException') {
        require $directory . '/src/NetherNetException.php';
        return;
    }
    $prefix = 'pocketmine\\nethernet\\protocol\\framing\\';
    if (!str_starts_with($class, $prefix)) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    require $directory . '/src/protocol/framing/' . substr($class, strlen($prefix)) . '.php';
});
$send = [];
$cases = [
    ['empty', '', 4], ['one', 'a', 1], ['short', 'hello', 8],
    ['exact', 'abcdefgh', 8], ['split', 'abcdefghij', 4],
    ['binary', "\x00\xff\x80\x00\x01\xfe\x7f", 2],
    ['maximum_fragment_count', str_repeat('x', 255), 1],
    ['too_many_fragments', str_repeat('x', 256), 1],
    ['invalid_zero_capacity', 'a', 0], ['invalid_large_capacity', 'a', 262144],
];
foreach ($cases as [$name, $payload, $capacity]) {
    $entry = ['name' => $name, 'payload_hex' => bin2hex($payload), 'capacity' => $capacity];
    try {
        $entry['frames_hex'] = array_map(bin2hex(...), (new Segmenter($capacity))->segment($payload));
    } catch (FramingException | InvalidArgumentException) {
        $entry['error'] = true;
    }
    $send[] = $entry;
}
$receive = [];
$cases = [
    ['whole', true, 8, ["\x00hello"]],
    ['split', true, 8, ["\x02ab", "\x01c", "\x00de"]],
    ['skip_then_recover', true, 8, ["\x03aa", "\x01bb", "\x00cc"]],
    ['duplicate_then_recover', true, 8, ["\x01aa", "\x01bb", "\x00cc"]],
    ['premature_final', true, 8, ["\x02aa", "\x00bb", "\x00cc"]],
    ['short_then_recover', true, 8, ['', "\x00", "\x00x"]],
    ['limit_then_recover', true, 4, ["\x01abc", "\x00de", "\x00x"]],
    ['unreliable', false, 8, ["\x00abc", "\x00def"]],
    ['unreliable_fragment_then_recover', false, 8, ["\x01abc", "\x00x"]],
    ['binary', true, 8, ["\x01\x00\xff", "\x00\x80\x00"]],
    ['byte_countdown_range', true, 256, array_map(static fn(int $n): string => chr($n) . 'x', range(255, 0))],
];
foreach ($cases as [$name, $reliable, $limit, $frames]) {
    $assembler = new Assembler($reliable, $limit);
    $results = [];
    foreach ($frames as $frame) {
        try {
            $value = $assembler->accept($frame);
            $results[] = $value === null ? ['pending' => true] : ['payload_hex' => bin2hex($value)];
        } catch (FramingException) {
            $results[] = ['error' => true];
        }
    }
    $receive[] = ['name' => $name, 'reliable' => $reliable, 'limit' => $limit,
        'frames_hex' => array_map(bin2hex(...), $frames), 'results' => $results];
}
$boundaries = [];
foreach ([262142, 262143, 262144, 262145, 524286] as $length) {
    $payload = substr(str_repeat("\x00\x7f\xff\x80", intdiv($length + 3, 4)), 0, $length);
    $frames = (new Segmenter())->segment($payload);
    $boundaries[] = ['length' => $length, 'payload_sha256' => hash('sha256', $payload),
        'frames' => array_map(static fn(string $frame): array => ['length' => strlen($frame),
            'header' => ord($frame[0]), 'sha256' => hash('sha256', $frame)], $frames)];
}
$data = ['oracle' => ['repository' => 'https://github.com/axolotl-pm/nethernet', 'branch' => 'master',
    'revision' => $revision, 'license' => 'LGPL-3.0-or-later'], 'send' => $send, 'receive' => $receive, 'boundaries' => $boundaries];
$encoded = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
file_put_contents(__DIR__ . '/../src/transport/fixtures/framing.json', $encoded);
$manifest = ['schema' => 1, 'oracle' => $data['oracle'], 'generator_sha256' => hash_file('sha256', __FILE__),
    'files' => ['framing.json' => ['bytes' => strlen($encoded), 'sha256' => hash('sha256', $encoded)]],
    'cases' => ['send' => count($send), 'receive' => count($receive), 'boundaries' => count($boundaries)]];
file_put_contents(__DIR__ . '/../src/transport/fixtures/manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
echo 'Generated ' . count($send) . ' send cases, ' . count($receive) . ' receive sequences and ' . count($boundaries) . " boundary cases\n";
