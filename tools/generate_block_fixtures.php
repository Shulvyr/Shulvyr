<?php

declare(strict_types=1);

use pocketmine\data\bedrock\block\BlockStateData;
use pocketmine\data\bedrock\block\BlockStateDeserializeException;
use pocketmine\nbt\TreeRoot;
use pocketmine\nbt\tag\ByteTag;
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\nbt\tag\IntTag;
use pocketmine\nbt\tag\StringTag;
use pocketmine\network\mcpe\convert\BlockStateDictionaryEntry;
use pocketmine\network\mcpe\protocol\serializer\NetworkNbtSerializer;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 5) {
    fwrite(STDERR, "Usage: php tools/generate_block_fixtures.php NBT_DIR BINARYUTILS_DIR BEDROCKPROTOCOL_DIR POCKETMINE_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
    exit(2);
}
$sources = [
    'NBT' => ['repository' => 'https://github.com/pmmp/NBT', 'branch' => 'stable', 'revision' => '5429a21c9321eb154f7fcdaa789d2b5ccbcc6ea3', 'prefix' => 'pocketmine\\nbt\\', 'directory' => $argv[1]],
    'BinaryUtils' => ['repository' => 'https://github.com/pmmp/BinaryUtils', 'branch' => 'stable', 'revision' => '14c044afa33cb581b4a6d1ea04a87e0bc99e824b', 'prefix' => 'pocketmine\\utils\\', 'directory' => $argv[2]],
    'BedrockProtocol' => ['repository' => 'https://github.com/axolotl-pm/BedrockProtocol', 'branch' => 'master', 'revision' => '59e48666b9ca82bdc8c60c518438e2fc3f5e1b60', 'prefix' => 'pocketmine\\network\\mcpe\\protocol\\', 'directory' => $argv[3]],
    'PocketMine-MP' => ['repository' => 'https://github.com/axolotl-pm/PocketMine-MP', 'branch' => 'stable', 'revision' => 'a550eea48212504f95b824eb3a1d67fc3b7f1861', 'prefix' => 'pocketmine\\', 'directory' => $argv[4]],
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
    if (gitOutput($source['directory'], ['rev-parse', 'HEAD']) !== $source['revision'] || gitOutput($source['directory'], ['status', '--porcelain', '--untracked-files=all']) !== '') {
        throw new RuntimeException("$name must be a clean checkout at the recorded default-branch revision");
    }
}
spl_autoload_register(static function (string $class) use ($sources): void {
    foreach ($sources as $source) {
        if (str_starts_with($class, $source['prefix'])) {
            $path = $source['directory'] . '/src/' . str_replace('\\', '/', substr($class, strlen($source['prefix']))) . '.php';
            if (is_file($path)) {
                require $path;
                return;
            }
        }
    }
    throw new RuntimeException('Unexpected oracle dependency: ' . $class);
});
function normalized(BlockStateData $state): array {
    $properties = $state->getStates();
    ksort($properties, SORT_STRING);
    $result = [];
    foreach ($properties as $name => $tag) {
        $kind = match ($tag->getType()) { 1 => 'byte', 3 => 'int', 8 => 'string', default => throw new RuntimeException('Unsupported palette property') };
        $result[] = ['name' => (string) $name, 'kind' => $kind, 'number' => $kind === 'string' ? null : $tag->getValue(), 'text' => $kind === 'string' ? $tag->getValue() : null];
    }
    return ['name' => $state->getName(), 'version' => $state->getVersion(), 'properties' => $result];
}
$root = dirname(__DIR__);
$directory = $root . '/src/registry/fixtures/blocks';
$input = json_decode(file_get_contents($directory . '/input.json'), true, 32, JSON_THROW_ON_ERROR);
if (!is_array($input) || count($input['cases']) > 64) {
    throw new RuntimeException('Invalid block fixture input');
}
$serializer = new NetworkNbtSerializer();
$expected = ['cases' => [], 'equalities' => []];
$states = [];
$files = ['input.json'];
foreach ($input['cases'] as $index => $case) {
    $properties = CompoundTag::create();
    foreach ($case['properties'] as $entry) {
        $properties->setTag($entry['name'], match ($entry['kind']) {
            'byte' => new ByteTag($entry['number']), 'int' => new IntTag($entry['number']),
            'string' => new StringTag($entry['text']), default => throw new RuntimeException('Unsupported fixture property'),
        });
    }
    $tag = CompoundTag::create()->setString('name', $case['name']);
    if (!($case['omit_states'] ?? false)) {
        $tag->setTag('states', $properties);
    }
    if (array_key_exists('version', $case)) {
        $tag->setTag('version', is_int($case['version']) ? new IntTag($case['version']) : new StringTag($case['version']));
    }
    if ($case['metadata'] ?? false) {
        $tag->setLong('PMMPDataVersion', 1);
    }
    if ($case['extra'] ?? false) {
        $tag->setInt('unexpected', 1);
    }
    $filename = "case-$index.network.nbt";
    $bytes = $serializer->write(new TreeRoot($tag));
    if (file_put_contents("$directory/$filename", $bytes) !== strlen($bytes)) {
        throw new RuntimeException('Cannot write block fixture');
    }
    $files[] = $filename;
    $offset = 0;
    try {
        $state = BlockStateData::fromNbt($serializer->read($bytes, $offset, 8)->mustGetCompoundTag());
        if ($offset !== strlen($bytes)) {
            throw new RuntimeException('Oracle did not consume its fixture');
        }
        $states[$index] = $state;
        $expected['cases'][] = ['file' => $filename, 'accepted' => true, 'state' => normalized($state), 'property_key_hex' => bin2hex(BlockStateDictionaryEntry::encodeStateProperties($state->getStates()))];
    } catch (BlockStateDeserializeException) {
        $expected['cases'][] = ['file' => $filename, 'accepted' => false, 'state' => null, 'property_key_hex' => null];
    }
}
foreach ($input['equality_pairs'] as [$a, $b]) {
    $expected['equalities'][] = ['a' => $a, 'b' => $b, 'equal' => $states[$a]->equals($states[$b])];
}
$dataDirectory = $root . '/data/bedrock';
$dataManifest = json_decode(file_get_contents($dataDirectory . '/manifest.json'), true, 16, JSON_THROW_ON_ERROR);
$palettePath = $dataDirectory . '/canonical_block_states.nbt';
if (hash_file('sha256', $palettePath) !== $dataManifest['files']['canonical_block_states.nbt']['sha256'] || filesize($palettePath) > 8 * 1024 * 1024) {
    throw new RuntimeException('Palette input hash or byte limit mismatch');
}
$palette = file_get_contents($palettePath);
$offset = 0;
$count = 0;
$propertyCount = 0;
$names = [];
$versions = [];
$semantic = hash_init('sha256');
while ($offset < strlen($palette)) {
    if (++$count > 65536) {
        throw new RuntimeException('Palette root limit');
    }
    $before = $offset;
    $state = BlockStateData::fromNbt($serializer->read($palette, $offset, 8)->mustGetCompoundTag());
    if ($offset <= $before || $offset - $before > 4096 || count($state->getStates()) > 32) {
        throw new RuntimeException('Palette root bounds');
    }
    normalized($state);
    $name = $state->getName();
    $properties = BlockStateDictionaryEntry::encodeStateProperties($state->getStates());
    hash_update($semantic, pack('V', strlen($name)) . $name . pack('V', strlen($properties)) . $properties);
    $names[$name] = true;
    $versions[$state->getVersion()] = true;
    $propertyCount += count($state->getStates());
}
$expected['palette'] = ['roots' => $count, 'names' => count($names), 'properties' => $propertyCount, 'versions' => array_keys($versions), 'semantic_sha256' => hash_final($semantic)];
$output = json_encode($expected, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
if (file_put_contents($directory . '/expected.json', $output) !== strlen($output)) {
    throw new RuntimeException('Cannot write block expectations');
}
$files[] = 'expected.json';
$manifest = ['schema' => 1, 'oracles' => array_map(static fn(array $source): array => ['repository' => $source['repository'], 'branch' => $source['branch'], 'revision' => $source['revision']], $sources), 'data_source' => $dataManifest['source'], 'palette_sha256' => hash('sha256', $palette), 'generator_sha256' => hash_file('sha256', __FILE__), 'files' => []];
foreach ($files as $file) {
    $manifest['files'][$file] = ['bytes' => filesize("$directory/$file"), 'sha256' => hash_file('sha256', "$directory/$file")];
}
$output = json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
if (file_put_contents($directory . '/manifest.json', $output) !== strlen($output)) {
    throw new RuntimeException('Cannot write block fixture manifest');
}
echo "Generated block schema fixtures and complete palette semantic hash\n";
