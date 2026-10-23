<?php

declare(strict_types=1);

// Development-only oracle. No Composer installation or project autoloader runs.
use pocketmine\nbt\BigEndianNbtSerializer;
use pocketmine\nbt\LittleEndianNbtSerializer;
use pocketmine\nbt\NBT;
use pocketmine\nbt\TreeRoot;
use pocketmine\nbt\tag\ByteArrayTag;
use pocketmine\nbt\tag\ByteTag;
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\nbt\tag\DoubleTag;
use pocketmine\nbt\tag\FloatTag;
use pocketmine\nbt\tag\IntArrayTag;
use pocketmine\nbt\tag\IntTag;
use pocketmine\nbt\tag\ListTag;
use pocketmine\nbt\tag\LongTag;
use pocketmine\nbt\tag\ShortTag;
use pocketmine\nbt\tag\StringTag;
use pocketmine\network\mcpe\protocol\serializer\NetworkNbtSerializer;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 4) {
    fwrite(STDERR, "Usage: php tools/generate_nbt_fixtures.php NBT_DIR BINARYUTILS_DIR BEDROCKPROTOCOL_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
    exit(2);
}

$sources = [
    'NBT' => [
        'repository' => 'https://github.com/pmmp/NBT', 'branch' => 'stable',
        'revision' => '5429a21c9321eb154f7fcdaa789d2b5ccbcc6ea3',
        'prefix' => 'pocketmine\\nbt\\', 'directory' => $argv[1],
    ],
    'BinaryUtils' => [
        'repository' => 'https://github.com/pmmp/BinaryUtils', 'branch' => 'stable',
        'revision' => '14c044afa33cb581b4a6d1ea04a87e0bc99e824b',
        'prefix' => 'pocketmine\\utils\\', 'directory' => $argv[2],
    ],
    'BedrockProtocol' => [
        'repository' => 'https://github.com/axolotl-pm/BedrockProtocol', 'branch' => 'master',
        'revision' => '59e48666b9ca82bdc8c60c518438e2fc3f5e1b60',
        'prefix' => 'pocketmine\\network\\mcpe\\protocol\\', 'directory' => $argv[3],
    ],
];

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

foreach ($sources as $name => $source) {
    if (gitOutput($source['directory'], ['rev-parse', 'HEAD']) !== $source['revision'] ||
        gitOutput($source['directory'], ['status', '--porcelain', '--untracked-files=all']) !== '') {
        throw new RuntimeException("$name must be a clean checkout at its pinned revision");
    }
}

spl_autoload_register(static function (string $class) use ($sources): void {
    foreach ($sources as $source) {
        if (str_starts_with($class, $source['prefix'])) {
            $relative = str_replace('\\', '/', substr($class, strlen($source['prefix'])));
            require $source['directory'] . '/src/' . $relative . '.php';
            return;
        }
    }
    throw new RuntimeException('Unexpected oracle dependency: ' . $class);
});

// Synthetic input, shared by the three upstream serializers.
$root = new TreeRoot(CompoundTag::create()
    ->setTag('byte', new ByteTag(-128))
    ->setTag('short', new ShortTag(-32768))
    ->setTag('int', new IntTag(-2147483648))
    ->setTag('long', new LongTag(PHP_INT_MIN))
    ->setTag('float', new FloatTag(1.5))
    ->setTag('double', new DoubleTag(-2.25))
    ->setTag('bytes', new ByteArrayTag("\x00\x7f\x80\xff"))
    ->setTag('string', new StringTag("\x00\xc3\xa9\xff"))
    ->setTag('ints', new IntArrayTag([-2147483648, -1, 0, 1, 2147483647]))
    ->setTag('list', new ListTag([new LongTag(PHP_INT_MIN), new LongTag(PHP_INT_MAX)]))
    ->setTag('nested', CompoundTag::create()->setString('value', 'ok'))
    ->setTag('empty', new ListTag())
    ->setTag('typed', new ListTag([], NBT::TAG_Short)), 'root');
$cases = [
    'all-tags' => $root,
    'scalar' => new TreeRoot(new LongTag(PHP_INT_MAX), 'r'),
    'nested-lists' => new TreeRoot(new ListTag([
        new ListTag([new IntTag(-1), new IntTag(128)]),
        new ListTag([], NBT::TAG_Int),
    ])),
];
$directory = dirname(__DIR__) . '/src/foundation/fixtures/nbt';
if (!is_dir($directory) && !mkdir($directory, 0777, true)) {
    throw new RuntimeException('Cannot create fixture directory');
}
$manifest = [
    'schema' => 2,
    'sources' => array_map(static fn(array $source): array => [
        'repository' => $source['repository'], 'branch' => $source['branch'], 'revision' => $source['revision'],
    ], $sources),
    'generator_sha256' => hash_file('sha256', __FILE__),
    'files' => [],
];
foreach (['big' => new BigEndianNbtSerializer(), 'little' => new LittleEndianNbtSerializer(), 'network' => new NetworkNbtSerializer()] as $format => $serializer) {
    foreach ($cases as $name => $tree) {
        $bytes = $serializer->write($tree);
        $offset = 0;
        $decoded = $serializer->read($bytes, $offset, 64);
        if ($offset !== strlen($bytes) || $serializer->write($decoded) !== $bytes) {
            throw new RuntimeException('Oracle round trip failed');
        }
        $filename = "$name.$format.nbt";
        if (file_put_contents("$directory/$filename", $bytes) !== strlen($bytes)) {
            throw new RuntimeException('Cannot write fixture');
        }
        $manifest['files'][$filename] = ['bytes' => strlen($bytes), 'sha256' => hash('sha256', $bytes)];
    }
    $bytes = $serializer->writeMultiple(array_values($cases));
    $decoded = $serializer->readMultiple($bytes, 64);
    if (count($decoded) !== count($cases) || $serializer->writeMultiple($decoded) !== $bytes) {
        throw new RuntimeException('Oracle sequence round trip failed');
    }
    $filename = "sequence.$format.nbt";
    if (file_put_contents("$directory/$filename", $bytes) !== strlen($bytes)) {
        throw new RuntimeException('Cannot write sequence fixture');
    }
    $manifest['files'][$filename] = ['bytes' => strlen($bytes), 'sha256' => hash('sha256', $bytes)];
}
$json = json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
if (file_put_contents("$directory/manifest.json", $json) !== strlen($json)) {
    throw new RuntimeException('Cannot write fixture manifest');
}
echo 'Generated ', count($manifest['files']), " pinned NBT fixtures\n";
