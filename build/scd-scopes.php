<?php
/**
 * Adds the default store scopes to app/etc/config.php for the duration of
 * setup:static-content:deploy, and no longer -- scopes left in the shipped
 * image are a second source of truth that app:config:import reconciles
 * against the database on every deploy, so the caller must restore the file.
 *
 * @see docs/architecture.md Why the build-time deploy needs them
 */

$path = $argv[1] ?? null;
if ($path === null || !is_file($path)) {
    fwrite(STDERR, "scd-scopes: no config.php at " . var_export($path, true) . PHP_EOL);
    exit(1);
}

$config = include $path;
if (!is_array($config)) {
    fwrite(STDERR, "scd-scopes: {$path} did not return an array\n");
    exit(1);
}

if (isset($config['scopes'])) {
    fwrite(STDERR, "scd-scopes: scopes already present, leaving {$path} alone\n");
    exit(0);
}

$config['scopes'] = [
    'websites' => [
        'admin' => [
            'website_id' => '0',
            'code' => 'admin',
            'name' => 'Admin',
            'sort_order' => '0',
            'default_group_id' => '0',
            'is_default' => '0',
        ],
        'base' => [
            'website_id' => '1',
            'code' => 'base',
            'name' => 'Main Website',
            'sort_order' => '0',
            'default_group_id' => '1',
            'is_default' => '1',
        ],
    ],
    'groups' => [
        0 => [
            'group_id' => '0',
            'website_id' => '0',
            'code' => 'default',
            'name' => 'Default',
            'root_category_id' => '0',
            'default_store_id' => '0',
        ],
        1 => [
            'group_id' => '1',
            'website_id' => '1',
            'code' => 'main_website_store',
            'name' => 'Main Website Store',
            'root_category_id' => '2',
            'default_store_id' => '1',
        ],
    ],
    'stores' => [
        'admin' => [
            'store_id' => '0',
            'code' => 'admin',
            'website_id' => '0',
            'group_id' => '0',
            'name' => 'Admin',
            'sort_order' => '0',
            'is_active' => '1',
        ],
        'default' => [
            'store_id' => '1',
            'code' => 'default',
            'website_id' => '1',
            'group_id' => '1',
            'name' => 'Default Store View',
            'sort_order' => '0',
            'is_active' => '1',
        ],
    ],
];

$written = file_put_contents(
    $path,
    "<?php\nreturn " . var_export($config, true) . ";\n"
);
if ($written === false) {
    fwrite(STDERR, "scd-scopes: could not write {$path}\n");
    exit(1);
}

fwrite(STDERR, "scd-scopes: added the default scopes to {$path} for the static deploy\n");
