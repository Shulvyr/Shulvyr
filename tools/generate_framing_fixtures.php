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
    $prefix = 'pocketmine\\nethernet\\';
    if (!str_starts_with($class, $prefix)) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    $relative = substr($class, strlen($prefix));
    if ($relative === 'FakePeerTransport' || $relative === 'FakeMessageChannel') {
        require $directory . '/tests/phpunit/' . $relative . '.php';
        return;
    }
    require $directory . '/src/' . str_replace('\\', '/', $relative) . '.php';
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
$receipts = [];
$receiptCases = [
    ['watermarks', [['abcdef', true], ['x', true], ['uv', false]], [0, 0], [[10, 3], [2, 3], [0, 3], [0, 0], [0, 0]]],
    ['empty_control', [['', true]], [100, 0], [[100, 0], [0, 0], [0, 0]]],
    ['empty_fifo', [['a', true], ['', true], ['bb', true]], [0, 0], [[5, 0], [3, 0], [0, 0]]],
    ['both_ready', [['a', true], ['b', false], ['c', true]], [0, 0], [[4, 2], [0, 0], [0, 0]]],
    ['overreported', [['abc', true]], [0, 0], [[8, 0], [4, 0], [3, 0], [0, 0]]],
    ['partial_drain', [['abcdef', true], ['x', true]], [0, 0], [[10, 0], [9, 0], [3, 0], [2, 0], [1, 0], [0, 0]]],
];
foreach ($receiptCases as [$name, $packets, $control, $snapshots]) {
    $transport = new \pocketmine\nethernet\FakePeerTransport();
    $transport->state = \pocketmine\nethernet\transport\TransportState::CONNECTED;
    $reliable = new \pocketmine\nethernet\FakeMessageChannel(\pocketmine\nethernet\protocol\Reliability::RELIABLE);
    $unreliable = new \pocketmine\nethernet\FakeMessageChannel(\pocketmine\nethernet\protocol\Reliability::UNRELIABLE);
    $session = new \pocketmine\nethernet\session\Session(7, $transport,
        new \pocketmine\nethernet\transport\ChannelPair($reliable, $unreliable),
        new \pocketmine\nethernet\utils\InternetAddress('192.0.2.10', 5000, 4), null,
        new Segmenter(4), new \pocketmine\nethernet\transport\ConnectionBudgetConfiguration());
    $inputs = [];
    foreach ($packets as $index => [$payload, $isReliable]) {
        $session->send($payload, $isReliable ? \pocketmine\nethernet\protocol\Reliability::RELIABLE : \pocketmine\nethernet\protocol\Reliability::UNRELIABLE, $index + 1);
        $inputs[] = ['payload_hex' => bin2hex($payload), 'reliable' => $isReliable];
    }
    $phases = [];
    foreach ($snapshots as [$r, $u]) {
        $reliable->buffered = $r;
        $unreliable->buffered = $u;
        $phases[] = ['buffered' => [$r, $u], 'acknowledged' => $session->takeAcknowledgedReceipts()];
    }
    $receipts[] = ['name' => $name, 'packets' => $inputs, 'control_buffered' => $control, 'phases' => $phases];
}
$receiptEncoded = json_encode(['oracle' => $data['oracle'], 'cases' => $receipts], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
file_put_contents(__DIR__ . '/../src/transport/fixtures/receipts.json', $receiptEncoded);
$lifecycle = [];
$lifecycleCases = [
    ['drained', 'abcdef', [[0, 8, 'CONNECTED'], [1000000000, 0, 'CONNECTED']]],
    ['deadline', 'abcdef', [[5000000000, 8, 'CONNECTED'], [6999999999, 8, 'CONNECTED'], [7000000000, 8, 'CONNECTED']]],
    ['empty_control', '', [[0, 100, 'CONNECTED'], [1000000000, 0, 'CONNECTED']]],
    ['empty_deadline', '', [[0, 100, 'CONNECTED'], [2000000000, 0, 'CONNECTED']]],
    ['empty', null, [[0, 0, 'CONNECTED']]],
    ['remote_closed', 'abcdef', [[0, 8, 'CONNECTED'], [1000000000, 8, 'CLOSED']]],
    ['transport_failed', 'abcdef', [[0, 8, 'CONNECTED'], [1000000000, 8, 'FAILED']]],
];
foreach ($lifecycleCases as [$name, $payload, $snapshots]) {
    $transport = new \pocketmine\nethernet\FakePeerTransport();
    $transport->state = \pocketmine\nethernet\transport\TransportState::CONNECTED;
    $reliable = new \pocketmine\nethernet\FakeMessageChannel(\pocketmine\nethernet\protocol\Reliability::RELIABLE);
    $unreliable = new \pocketmine\nethernet\FakeMessageChannel(\pocketmine\nethernet\protocol\Reliability::UNRELIABLE);
    $session = new \pocketmine\nethernet\session\Session(7, $transport,
        new \pocketmine\nethernet\transport\ChannelPair($reliable, $unreliable),
        new \pocketmine\nethernet\utils\InternetAddress('192.0.2.10', 5000, 4), null,
        new Segmenter(4), new \pocketmine\nethernet\transport\ConnectionBudgetConfiguration());
    if ($payload !== null) {
        $session->send($payload, \pocketmine\nethernet\protocol\Reliability::RELIABLE, 1);
    }
    $session->initiateDisconnect(\pocketmine\nethernet\protocol\DisconnectReason::SERVER_DISCONNECT);
    $phases = [];
    foreach ($snapshots as $index => [$time, $buffered, $state]) {
        $reliable->buffered = $buffered;
        $transport->state = constant(\pocketmine\nethernet\transport\TransportState::class . '::' . $state);
        if ($index > 0) {
            $session->initiateDisconnect(\pocketmine\nethernet\protocol\DisconnectReason::SERVER_DISCONNECT);
        }
        $acknowledged = $session->takeAcknowledgedReceipts();
        $session->update($time / 1000000000);
        $phases[] = ['time_ns' => $time, 'buffered' => $buffered, 'transport' => $state,
            'acknowledged' => $acknowledged, 'connected' => $session->isConnected(),
            'disconnected' => $session->isFullyDisconnected(), 'reason' => $session->getDisconnectReason()?->name];
    }
    $lifecycle[] = ['name' => $name, 'payload_hex' => $payload !== null ? bin2hex($payload) : null, 'phases' => $phases];
}
$lifecycleEncoded = json_encode(['oracle' => $data['oracle'],
    'packet_limit' => \pocketmine\nethernet\server\SessionManager::PACKETS_PER_TICK_LIMIT,
    'flush_timeout_ns' => (int) (\pocketmine\nethernet\session\Session::DISCONNECT_FLUSH_TIMEOUT * 1000000000),
    'cases' => $lifecycle], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
file_put_contents(__DIR__ . '/../src/transport/fixtures/lifecycle.json', $lifecycleEncoded);
$manifest = ['schema' => 1, 'oracle' => $data['oracle'], 'generator_sha256' => hash_file('sha256', __FILE__),
    'files' => ['framing.json' => ['bytes' => strlen($encoded), 'sha256' => hash('sha256', $encoded)],
        'receipts.json' => ['bytes' => strlen($receiptEncoded), 'sha256' => hash('sha256', $receiptEncoded)],
        'lifecycle.json' => ['bytes' => strlen($lifecycleEncoded), 'sha256' => hash('sha256', $lifecycleEncoded)]],
    'cases' => ['send' => count($send), 'receive' => count($receive), 'boundaries' => count($boundaries), 'receipts' => count($receipts), 'lifecycle' => count($lifecycle)]];
file_put_contents(__DIR__ . '/../src/transport/fixtures/manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
echo 'Generated ' . count($send) . ' send cases, ' . count($receive) . ' receive sequences, ' . count($boundaries) . ' boundary cases, ' . count($receipts) . ' receipt sequences and ' . count($lifecycle) . " lifecycle sequences\n";
