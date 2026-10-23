<?php

declare(strict_types=1);

use pocketmine\math\AxisAlignedBB;
use pocketmine\math\Vector3;
use pocketmine\math\VoxelRayTrace;

if (PHP_VERSION_ID < 80400 || PHP_INT_SIZE !== 8 || $argc !== 2) {
    fwrite(STDERR, "Usage: php tools/generate_math_fixtures.php MATH_DIR\nRequires 64-bit PHP 8.4 or newer and Git\n");
    exit(2);
}
$directory = $argv[1];
$revision = 'd74ed5a788092df8e8ec15609b36535ed96587f9';
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
    throw new RuntimeException('Math must be a clean checkout at the recorded default-branch revision');
}
spl_autoload_register(static function (string $class) use ($directory): void {
    $prefix = 'pocketmine\\math\\';
    if (!str_starts_with($class, $prefix)) {
        throw new RuntimeException('Unexpected oracle dependency: ' . $class);
    }
    require $directory . '/src/' . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
});
function point(Vector3 $vector): array {
    return [$vector->x, $vector->y, $vector->z];
}
$data = ['vectors' => [], 'boxes' => [], 'rays' => [], 'voxels' => []];
foreach ([[0, 0, 0], [3, 4, 0], [-1.25, 2.5, -3.75], [0.00001, -0.00001, 0.00001], [1000000000, -1000000000, 1000000000], [2, 3, 6]] as $coordinates) {
    $a = new Vector3(...$coordinates);
    $b = new Vector3(-4, 2, 1);
    $data['vectors'][] = [
        'a' => point($a), 'b' => point($b),
        'add' => point($a->addVector($b)), 'sub' => point($a->subtractVector($b)),
        'scale' => point($a->multiply(0.5)), 'dot' => $a->dot($b),
        'cross' => point($a->cross($b)), 'normal' => point($a->normalize()),
        'length_squared' => $a->lengthSquared(), 'distance_squared' => $a->distanceSquared($b),
        'floor' => point($a->floor()),
    ];
}
$boxes = [
    [0, 0, 0, 1, 1, 1], [1, 0, 0, 2, 1, 1],
    [0.999995, 0, 0, 2, 1, 1], [0.99998, 0, 0, 2, 1, 1],
    [-3, -2, -1, -1, 0, 1], [0, 0, 0, 0, 2, 2],
    [0.5, 0.25, 0.25, 0.5, 0.75, 0.75],
    [-2, 0.25, 0.25, -1, 0.75, 0.75], [2, 0.25, 0.25, 3, 0.75, 0.75],
    [0.25, -2, 0.25, 0.75, -1, 0.75], [0.25, 2, 0.25, 0.75, 3, 0.75],
    [0.25, 0.25, -2, 0.75, 0.75, -1], [0.25, 0.25, 2, 0.75, 0.75, 3],
];
foreach ($boxes as $coordinates) {
    foreach ([0.0, 0.00001] as $epsilon) {
        $a = AxisAlignedBB::one();
        $b = new AxisAlignedBB(...$coordinates);
        $position = new Vector3($coordinates[0], 0.5, 0.5);
        $data['boxes'][] = [
            'a' => [0, 0, 0, 1, 1, 1], 'b' => $coordinates, 'point' => point($position),
            'epsilon' => $epsilon, 'contains' => $a->isVectorInside($position),
            'intersects' => $a->intersectsWith($b, $epsilon),
            'positive_offsets' => [$a->calculateXOffset($b, 4), $a->calculateYOffset($b, 4), $a->calculateZOffset($b, 4)],
            'negative_offsets' => [$a->calculateXOffset($b, -4), $a->calculateYOffset($b, -4), $a->calculateZOffset($b, -4)],
        ];
    }
}
$segments = [
    [[-1, 0.5, 0.5], [2, 0.5, 0.5]], [[2, 0.5, 0.5], [-1, 0.5, 0.5]],
    [[0.5, -1, 0.5], [0.5, 2, 0.5]], [[0.5, 2, 0.5], [0.5, -1, 0.5]],
    [[0.5, 0.5, -1], [0.5, 0.5, 2]], [[0.5, 0.5, 2], [0.5, 0.5, -1]],
    [[-1, -1, -1], [2, 2, 2]], [[2, 2, 2], [-1, -1, -1]],
    [[0.5, 0.5, 0.5], [2, 2, 2]], [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
    [[-1, 2, 0.5], [2, 2, 0.5]], [[-1, 0, 0], [0, 0, 0]],
    [[0, 0.5, 0.5], [-1, 0.5, 0.5]], [[-0.00005, 0.5, 0.5], [0.00005, 0.5, 0.5]],
    [[-0.0005, 0.5, 0.5], [0.0005, 0.5, 0.5]],
    [[-2147483648, -2147483648, -2147483648], [2147483647, 2147483647, 2147483647]],
];
foreach ($segments as [$start, $end]) {
    $box = AxisAlignedBB::one();
    $hit = $box->calculateIntercept(new Vector3(...$start), new Vector3(...$end));
    $data['rays'][] = [
        'box' => [0, 0, 0, 1, 1, 1], 'start' => $start, 'end' => $end,
        'hit' => $hit === null ? null : ['face' => $hit->hitFace, 'point' => point($hit->hitVector)],
    ];
}
$voxelSegments = [
    [[0.5, 0.5, 0.5], [0.75, 0.75, 0.75]],
    [[0, 0, 0], [-1, -1, -1]], [[-1, -1, -1], [0, 0, 0]],
    [[-0.1, -16, 15.5], [-2.1, -16, 17.5]],
    [[0.5, 0.5, 0.5], [2, 0.5, 0.5]], [[0.5, 0.5, 0.5], [0, 0.5, 0.5]],
];
foreach ([-1, 0, 1] as $x) {
    foreach ([-1, 0, 1] as $y) {
        foreach ([-1, 0, 1] as $z) {
            if ($x !== 0 || $y !== 0 || $z !== 0) {
                $voxelSegments[] = [[0.5, 0.5, 0.5], [0.5 + 2 * $x, 0.5 + 2 * $y, 0.5 + 2 * $z]];
            }
        }
    }
}
foreach ($voxelSegments as [$start, $end]) {
    $cells = [];
    foreach (VoxelRayTrace::betweenPoints(new Vector3(...$start), new Vector3(...$end)) as $cell) {
        $cells[] = point($cell);
        if (count($cells) > 128) {
            throw new RuntimeException('Oracle voxel case exceeded its work budget');
        }
    }
    $data['voxels'][] = ['start' => $start, 'end' => $end, 'cells' => $cells];
}
$output = dirname(__DIR__) . '/src/math/fixtures';
if (!is_dir($output) && !mkdir($output, 0777, true)) {
    throw new RuntimeException('Cannot create fixture directory');
}
$json = json_encode($data, JSON_PRETTY_PRINT | JSON_PRESERVE_ZERO_FRACTION | JSON_THROW_ON_ERROR) . "\n";
if (file_put_contents("$output/conformance.json", $json) !== strlen($json)) {
    throw new RuntimeException('Cannot write math fixtures');
}
$manifest = [
    'schema' => 1,
    'oracle' => ['repository' => 'https://github.com/pmmp/Math', 'branch' => 'stable', 'revision' => $revision],
    'generator_sha256' => hash_file('sha256', __FILE__),
    'files' => ['conformance.json' => ['bytes' => strlen($json), 'sha256' => hash('sha256', $json)]],
];
$metadata = json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
if (file_put_contents("$output/manifest.json", $metadata) !== strlen($metadata)) {
    throw new RuntimeException('Cannot write math manifest');
}
echo 'Generated ', array_sum(array_map('count', $data)), " math oracle cases\n";
