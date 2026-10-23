<?php

declare(strict_types=1);

// Development-only identity oracle. No upstream build or Composer scripts run.
use pocketmine\nbt\tag\CompoundTag;
use pocketmine\network\mcpe\protocol\serializer\ItemTypeDictionary;
use pocketmine\network\mcpe\protocol\types\CacheableNbt;
use pocketmine\network\mcpe\protocol\types\ItemTypeEntry;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 3) {
    fwrite(STDERR, "Usage: php tools/generate_registry_fixtures.php NBT_DIR BEDROCKPROTOCOL_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
    exit(2);
}
$sources = [
    'NBT' => [
        'repository' => 'https://github.com/pmmp/NBT', 'branch' => 'stable',
        'revision' => '5429a21c9321eb154f7fcdaa789d2b5ccbcc6ea3',
        'prefix' => 'pocketmine\\nbt\\', 'directory' => $argv[1],
    ],
    'BedrockProtocol' => [
        'repository' => 'https://github.com/axolotl-pm/BedrockProtocol', 'branch' => 'master',
        'revision' => '59e48666b9ca82bdc8c60c518438e2fc3f5e1b60',
        'prefix' => 'pocketmine\\network\\mcpe\\protocol\\', 'directory' => $argv[2],
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
        throw new RuntimeException("$name must be a clean checkout at the recorded default-branch revision");
    }
}
spl_autoload_register(static function (string $class) use ($sources): void {
    foreach ($sources as $source) {
        if (str_starts_with($class, $source['prefix'])) {
            require $source['directory'] . '/src/' . str_replace('\\', '/', substr($class, strlen($source['prefix']))) . '.php';
            return;
        }
    }
    throw new RuntimeException('Unexpected oracle dependency: ' . $class);
});

function jsonFile(string $path): array {
    $bytes = file_get_contents($path);
    if ($bytes === false || strlen($bytes) > 2 * 1024 * 1024) {
        throw new RuntimeException('Missing or oversized fixture input');
    }
    $value = json_decode($bytes, true, 64, JSON_THROW_ON_ERROR);
    if (!is_array($value)) {
        throw new RuntimeException('Fixture input must be an object');
    }
    return $value;
}
function dictionary(array $rows): ItemTypeDictionary {
    $entries = [];
    $names = [];
    $ids = [];
    foreach ($rows as $row) {
        if (!is_array($row) || !isset($row['key'], $row['network_id']) ||
            !is_string($row['key']) || !is_int($row['network_id']) ||
            $row['network_id'] < -32768 || $row['network_id'] > 32767 ||
            isset($names[$row['key']]) || isset($ids[$row['network_id']])) {
            throw new RuntimeException('Invalid or duplicate oracle dictionary entry');
        }
        $names[$row['key']] = true;
        $ids[$row['network_id']] = true;
        // These lookups never inspect components. Supply a synthetic empty tag.
        $entries[] = new ItemTypeEntry($row['key'], $row['network_id'], false, 0, new CacheableNbt(CompoundTag::create()));
    }
    return new ItemTypeDictionary($entries);
}
function query(ItemTypeDictionary $dictionary, array $query): array {
    if (count($query) !== 1 || (!array_key_exists('key', $query) && !array_key_exists('network_id', $query))) {
        throw new RuntimeException('Each query needs exactly one lookup direction');
    }
    try {
        if (array_key_exists('key', $query)) {
            if (!is_string($query['key'])) {
                throw new RuntimeException('Query key must be a string');
            }
            $name = $query['key'];
            $id = $dictionary->fromStringId($name);
        } else {
            if (!is_int($query['network_id'])) {
                throw new RuntimeException('Query ID must be an integer');
            }
            $id = $query['network_id'];
            $name = $dictionary->fromIntId($id);
        }
        return ['found' => true, 'key' => $name, 'network_id' => $id];
    } catch (InvalidArgumentException) {
        return ['found' => false, 'key' => null, 'network_id' => null];
    }
}
$root = dirname(__DIR__);
$directory = $root . '/src/registry/fixtures';
$input = jsonFile($directory . '/input.json');
$dataManifest = jsonFile($root . '/data/bedrock/manifest.json');
$itemPath = $root . '/data/bedrock/required_item_list.json';
$itemHash = hash_file('sha256', $itemPath);
if ($itemHash !== $dataManifest['files']['required_item_list.json']['sha256']) {
    throw new RuntimeException('BedrockData input hash mismatch');
}
$sourceRows = [];
foreach (jsonFile($itemPath) as $key => $entry) {
    $sourceRows[] = ['key' => $key, 'network_id' => $entry['runtime_id']];
}
usort($sourceRows, static fn(array $a, array $b): int => strcmp($a['key'], $b['key']));
$sourceDictionary = dictionary($sourceRows);
$syntheticDictionary = dictionary($input['synthetic_entries']);
$mapping = '';
foreach ($sourceRows as $row) {
    $id = $sourceDictionary->fromStringId($row['key']);
    $key = $sourceDictionary->fromIntId($id);
    if ($key !== $row['key'] || $id !== $row['network_id']) {
        throw new RuntimeException('Oracle dictionary is not reversible');
    }
    $mapping .= $key . "\t" . $id . "\n";
}
$output = [
    'source_entry_count' => count($sourceRows),
    'source_mapping_sha256' => hash('sha256', $mapping),
    'synthetic_answers' => array_map(static fn(array $entry): array => query($syntheticDictionary, $entry), $input['synthetic_queries']),
    'source_answers' => array_map(static fn(array $entry): array => query($sourceDictionary, $entry), $input['source_queries']),
];
$bytes = json_encode($output, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
if (file_put_contents($directory . '/expected.json', $bytes) !== strlen($bytes)) {
    throw new RuntimeException('Cannot write registry fixture');
}
$manifest = [
    'schema' => 1,
    'oracles' => array_map(static fn(array $source): array => [
        'repository' => $source['repository'], 'branch' => $source['branch'], 'revision' => $source['revision'],
    ], $sources),
    'data_source' => $dataManifest['source'],
    'data_sha256' => $itemHash,
    'generator_sha256' => hash_file('sha256', __FILE__),
    'files' => [],
];
foreach (['input.json', 'expected.json'] as $name) {
    $manifest['files'][$name] = ['bytes' => filesize($directory . '/' . $name), 'sha256' => hash_file('sha256', $directory . '/' . $name)];
}
$bytes = json_encode($manifest, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
if (file_put_contents($directory . '/manifest.json', $bytes) !== strlen($bytes)) {
    throw new RuntimeException('Cannot write registry fixture manifest');
}
echo 'Generated registry lookup fixtures and complete oracle mapping hash' . PHP_EOL;
