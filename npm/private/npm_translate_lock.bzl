"Convert pnpm lock file into starlark Bazel fetches"

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load(":utils.bzl", "utils")
load(":transitive_closure.bzl", "translate_to_transitive_closure")
load(":starlark_codegen_utils.bzl", "starlark_codegen_utils")

_DOC = """Repository rule to generate npm_import rules from pnpm lock file.

The pnpm lockfile format includes all the information needed to define npm_import rules,
including the integrity hash, as calculated by the package manager.

For more details see, https://github.com/pnpm/pnpm/blob/main/packages/lockfile-types/src/index.ts.

Instead of manually declaring the `npm_imports`, this helper generates an external repository
containing a helper starlark module `repositories.bzl`, which supplies a loadable macro
`npm_repositories`. This macro creates an `npm_import` for each package.

The generated repository also contains BUILD files declaring targets for the packages
listed as `dependencies` or `devDependencies` in `package.json`, so you can declare
dependencies on those packages without having to repeat version information.

Bazel will only fetch the packages which are required for the requested targets to be analyzed.
Thus it is performant to convert a very large pnpm-lock.yaml file without concern for
users needing to fetch many unnecessary packages.

**Setup**

In `WORKSPACE`, call the repository rule pointing to your pnpm-lock.yaml file:

```starlark
load("@aspect_rules_js//npm:npm_import.bzl", "npm_translate_lock")

# Read the pnpm-lock.yaml file to automate creation of remaining npm_import rules
npm_translate_lock(
    # Creates a new repository named "@npm_deps"
    name = "npm_deps",
    pnpm_lock = "//:pnpm-lock.yaml",
)
```

Next, there are two choices, either load from the generated repo or check in the generated file.
The tradeoffs are similar to
[this rules_python thread](https://github.com/bazelbuild/rules_python/issues/608).

1. Immediately load from the generated `repositories.bzl` file in `WORKSPACE`.
This is similar to the 
[`pip_parse`](https://github.com/bazelbuild/rules_python/blob/main/docs/pip.md#pip_parse)
rule in rules_python for example.
It has the advantage of also creating aliases for simpler dependencies that don't require
spelling out the version of the packages.
However it causes Bazel to eagerly evaluate the `npm_translate_lock` rule for every build,
even if the user didn't ask for anything JavaScript-related.

```starlark
load("@npm_deps//:repositories.bzl", "npm_repositories")

npm_repositories()
```

In BUILD files, declare dependencies on the packages using the same external repository.

Following the same example, this might look like:

```starlark
js_test(
    name = "test_test",
    data = ["@npm_deps//@types/node"],
    entry_point = "test.js",
)
```

2. Check in the `repositories.bzl` file to version control, and load that instead.
This makes it easier to ship a ruleset that has its own npm dependencies, as users don't
have to install those dependencies. It also avoids eager-evaluation of `npm_translate_lock`
for builds that don't need it.
This is similar to the [`update-repos`](https://github.com/bazelbuild/bazel-gazelle#update-repos)
approach from bazel-gazelle.

In a BUILD file, use a rule like
[write_source_files](https://github.com/aspect-build/bazel-lib/blob/main/docs/write_source_files.md)
to copy the generated file to the repo and test that it stays updated:

```starlark
write_source_files(
    name = "update_repos",
    files = {
        "repositories.bzl": "@npm_deps//:repositories.bzl",
    },
)
```

Then in `WORKSPACE`, load from that checked-in copy or instruct your users to do so.
In this case, the aliases are not created, so you get only the `npm_import` behavior
and must depend on packages with their versioned label like `@npm__types_node-15.12.2`.
"""

_ATTRS = {
    "pnpm_lock": attr.label(
        doc = """The pnpm-lock.yaml file.""",
        mandatory = True,
    ),
    "patches": attr.string_list_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a label list of patches to apply to the downloaded npm package. Paths in the patch
        file must start with `extract_tmp/package` where `package` is the top-level folder in
        the archive on npm. If the version is left out of the package name, the patch will be
        applied to every version of the npm package.""",
    ),
    "patch_args": attr.string_list_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a label list arguments to pass to the patch tool. Defaults to -p0, but -p1 will
        usually be needed for patches generated by git. If patch args exists for a package
        as well as a package version, then the version-specific args will be appended to the args for the package.""",
    ),
    "custom_postinstalls": attr.string_dict(
        doc = """A map of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to a custom postinstall script to apply to the downloaded npm package after its lifecycle scripts runs.
        If the version is left out of the package name, the script will run on every version of the npm package. If
        a custom postinstall scripts exists for a package as well as for a specific version, the script for the versioned package
        will be appended with `&&` to the non-versioned package script.""",
    ),
    "prod": attr.bool(
        doc = """If true, only install dependencies""",
    ),
    "dev": attr.bool(
        doc = """If true, only install devDependencies""",
    ),
    "no_optional": attr.bool(
        doc = """If true, optionalDependencies are not installed""",
    ),
    "lifecycle_hooks_exclude": attr.string_list(
        doc = """A list of package names or package names with their version (e.g., "my-package" or "my-package@v1.2.3")
        to not run lifecycle hooks on""",
    ),
    "run_lifecycle_hooks": attr.bool(
        doc = """If true, runs preinstall, install and postinstall lifecycle hooks on npm packages if they exist""",
        default = True,
    ),
}

def _process_lockfile(rctx):
    lockfile = utils.parse_pnpm_lock(rctx.read(rctx.path(rctx.attr.pnpm_lock)))
    return translate_to_transitive_closure(lockfile, rctx.attr.prod, rctx.attr.dev, rctx.attr.no_optional)

_NPM_IMPORT_TMPL = \
    """    npm_import(
        name = "{name}",
        root_package = "{root_package}",
        link_workspace = "{link_workspace}",
        link_packages = {link_packages},
        package = "{package}",
        version = "{version}",{maybe_integrity}{maybe_url}{maybe_deps}{maybe_transitive_closure}{maybe_patches}{maybe_patch_args}{maybe_run_lifecycle_hooks}{maybe_custom_postinstall}
    )
"""

_BIN_TMPL = \
    """load("@{repo_name}//{repo_package_json_bzl}", _bin = "bin", _bin_factory = "bin_factory")
bin = _bin
bin_factory = _bin_factory
"""

_FP_STORE_TMPL = \
    """
    if is_root:
         _npm_link_package_store(
            name = "{{}}/{package}/store/0.0.0".format(name),
            src = "{npm_package_target}",
            package = "{package}",
            version = "0.0.0",
            deps = {deps},
            visibility = ["//visibility:public"],
            tags = ["manual"],
        )"""

_FP_DIRECT_TMPL = \
    """
    for link_package in {link_packages}:
        if link_package == native.package_name():
            # terminal target for direct dependencies
            _npm_link_package_direct(
                name = "{{}}/{name}".format(name),
                src = "//{root_package}:{{}}/{package}/store/0.0.0".format(name),
                visibility = ["//visibility:public"],
                tags = ["manual"],
            )
            direct_targets.append(":{{}}/{name}".format(name))

            # filegroup target that provides a single file which is
            # package directory for use in $(execpath) and $(rootpath)
            native.filegroup(
                name = "{{}}/{name}/dir".format(name),
                srcs = [":{{}}/{name}".format(name)],
                output_group = "{package_directory_output_group}",
                visibility = ["//visibility:public"],
                tags = ["manual"],
            )
            """

_DEFS_BZL_FILENAME = "defs.bzl"
_REPOSITORIES_BZL_FILENAME = "repositories.bzl"
_PACKAGE_JSON_BZL_FILENAME = "package_json.bzl"

def _generated_by_lines(pnpm_lock_wksp, pnpm_lock):
    return [
        "\"@generated by @aspect_rules_js//npm/private:npm_translate_lock.bzl from pnpm lock file @{pnpm_lock_wksp}{pnpm_lock}\"".format(
            pnpm_lock_wksp = pnpm_lock_wksp,
            pnpm_lock = str(pnpm_lock),
        ),
        "",  # empty line after bzl docstring since buildifier expects this if this file is vendored in
    ]

def _link_package(root_package, import_path, rel_path = "."):
    link_package = paths.normalize(paths.join(root_package, import_path, rel_path))
    if link_package.startswith("../"):
        fail("Invalid link_package outside of the WORKSPACE: {}".format(link_package))
    if link_package == ".":
        link_package = ""
    return link_package

def _gen_npm_imports(lockfile, attr):
    "Converts packages from the lockfile to a struct of attributes for npm_import"

    if attr.prod and attr.dev:
        fail("prod and dev attributes cannot both be set to true")

    # root package is the directory of the pnpm_lock file
    root_package = attr.pnpm_lock.package

    # don't allow a pnpm lock file that isn't in the root directory of a bazel package
    if paths.dirname(attr.pnpm_lock.name):
        fail("pnpm-lock.yaml file must be at the root of a bazel package")

    packages = lockfile.get("packages")
    if not packages:
        fail("expected packages in processed lockfile")

    result = []
    for (i, v) in enumerate(packages.items()):
        (package, package_info) = v
        name = package_info.get("name")
        version = package_info.get("version")
        friendly_version = package_info.get("friendly_version")
        deps = package_info.get("dependencies")
        optional_deps = package_info.get("optionalDependencies")
        dev = package_info.get("dev")
        optional = package_info.get("optional")
        requires_build = package_info.get("requiresBuild")
        integrity = package_info.get("integrity")
        tarball = package_info.get("tarball")
        transitive_closure = package_info.get("transitiveClosure")

        if attr.prod and dev:
            # when prod attribute is set, skip devDependencies
            continue
        if attr.dev and not dev:
            # when dev attribute is set, skip (non-dev) dependencies
            continue
        if attr.no_optional and optional:
            # when no_optional attribute is set, skip optionalDependencies
            continue

        if not attr.no_optional:
            deps = dicts.add(optional_deps, deps)

        friendly_name = utils.friendly_name(name, friendly_version)
        unfriendly_name = utils.friendly_name(name, version)
        if unfriendly_name == friendly_name:
            # there is no unfriendly name for this package
            unfriendly_name = None

        # gather patches by name, friendly_name and unfriendly_name (if any)
        patches = attr.patches.get(name, [])[:]
        patches.extend(attr.patches.get(friendly_name, []))
        if unfriendly_name:
            patches.extend(attr.patches.get(unfriendly_name, []))
        patch_args = attr.patch_args.get(name, [])[:]
        patch_args.extend(attr.patch_args.get(friendly_name, []))
        if unfriendly_name:
            patch_args.extend(attr.patch_args.get(unfriendly_name, []))

        # gather custom postinstalls by name, friendly_name and unfriendly_name (if any)
        custom_postinstalls = []
        if name in attr.custom_postinstalls:
            custom_postinstalls.append(attr.custom_postinstalls.get(name))
        if friendly_name in attr.custom_postinstalls:
            custom_postinstalls.append(attr.custom_postinstalls.get(friendly_name))
        if unfriendly_name and unfriendly_name in attr.custom_postinstalls:
            custom_postinstalls.append(attr.custom_postinstalls.get(unfriendly_name))
        custom_postinstall = " && ".join([c for c in custom_postinstalls if c])

        repo_name = "%s__%s" % (attr.name, utils.bazel_name(name, version))
        if repo_name.startswith("aspect_rules_js.npm."):
            repo_name = repo_name[len("aspect_rules_js.npm."):]

        link_packages = {}

        for import_path, importer in lockfile.get("importers").items():
            dependencies = importer.get("dependencies")
            if type(dependencies) != "dict":
                fail("expected dict of dependencies in processed importer '%s'" % import_path)
            link_package = _link_package(root_package, import_path)
            for dep_package, dep_version in dependencies.items():
                if dep_version.startswith("link:"):
                    continue
                if dep_version.startswith("/"):
                    pnpm_name = dep_version[1:]
                else:
                    pnpm_name = utils.pnpm_name(dep_package, dep_version)
                if package == pnpm_name:
                    # this package is a direct dependency at this import path
                    if link_package not in link_packages:
                        link_packages[link_package] = [dep_package]
                    else:
                        link_packages[link_package].append(dep_package)

        run_lifecycle_hooks = (
            requires_build and
            attr.run_lifecycle_hooks and
            name not in attr.lifecycle_hooks_exclude and
            friendly_name not in attr.lifecycle_hooks_exclude
        )

        result.append(struct(
            custom_postinstall = custom_postinstall,
            deps = deps,
            integrity = integrity,
            link_packages = link_packages,
            name = repo_name,
            package = name,
            patch_args = patch_args,
            patches = patches,
            root_package = root_package,
            run_lifecycle_hooks = run_lifecycle_hooks,
            transitive_closure = transitive_closure,
            url = tarball,
            version = version,
        ))
    return result

def _impl(rctx):
    lockfile = _process_lockfile(rctx)

    # root package is the directory of the pnpm_lock file
    root_package = rctx.attr.pnpm_lock.package

    generated_by_lines = _generated_by_lines(rctx.attr.pnpm_lock.workspace_name, rctx.attr.pnpm_lock)

    repositories_bzl = generated_by_lines + [
        """load("@aspect_rules_js//npm:npm_import.bzl", "npm_import")""",
        "",
        "def npm_repositories():",
        "    \"Generated npm_import repository rules corresponding to npm packages in @{pnpm_lock_wksp}{pnpm_lock}\"".format(
            pnpm_lock_wksp = str(rctx.attr.pnpm_lock.workspace_name),
            pnpm_lock = str(rctx.attr.pnpm_lock),
        ),
    ]

    importers = lockfile.get("importers")
    if not importers:
        fail("expected importers in processed lockfile")

    importer_paths = importers.keys()

    direct_packages = [_link_package(root_package, import_path) for import_path in importer_paths]

    defs_bzl_header = generated_by_lines + ["""# buildifier: disable=bzl-visibility
load("@aspect_rules_js//npm/private:npm_linked_packages.bzl", "npm_linked_packages")"""]

    npm_imports = _gen_npm_imports(lockfile, rctx.attr)

    fp_links = {}

    # Look for first-party links
    for import_path, importer in importers.items():
        dependencies = importer.get("dependencies")
        if type(dependencies) != "dict":
            fail("expected dict of dependencies in processed importer '%s'" % import_path)
        link_package = _link_package(root_package, import_path)
        for dep_package, dep_version in dependencies.items():
            if dep_version.startswith("link:"):
                dep_importer = paths.normalize(paths.join(import_path, dep_version[len("link:"):]))
                dep_path = _link_package(root_package, import_path, dep_version[len("link:"):])
                dep_key = "{}+{}".format(dep_package, dep_path)
                if dep_key in fp_links.keys():
                    fp_links[dep_key]["link_packages"][link_package] = []
                else:
                    transitive_deps = {}
                    raw_deps = {}
                    if dep_importer in importers.keys():
                        raw_deps = importers.get(dep_importer).get("dependencies")
                    for raw_package, raw_version in raw_deps.items():
                        if raw_version.startswith("link:"):
                            dep_store_target = """"//{root_package}:{{}}/{package}/store/{version}".format(name)""".format(
                                root_package = root_package,
                                package = raw_package,
                                version = "0.0.0",
                            )
                        elif raw_version.startswith("/"):
                            store_package, store_version = utils.parse_pnpm_name(raw_version[1:])
                            dep_store_target = """"//{root_package}:{{}}/{package}/store/{version}".format(name)""".format(
                                root_package = root_package,
                                package = store_package,
                                version = store_version,
                            )
                        else:
                            dep_store_target = """"//{root_package}:{{}}/{package}/store/{version}".format(name)""".format(
                                root_package = root_package,
                                package = raw_package,
                                version = raw_version,
                            )
                        if dep_store_target not in transitive_deps:
                            transitive_deps[dep_store_target] = [raw_package]
                        else:
                            transitive_deps[dep_store_target].append(raw_package)

                    # collapse link aliases lists into to acomma separated strings
                    for dep_store_target in transitive_deps.keys():
                        transitive_deps[dep_store_target] = ",".join(transitive_deps[dep_store_target])
                    fp_links[dep_key] = {
                        "package": dep_package,
                        "path": dep_path,
                        "link_packages": {link_package: []},
                        "deps": transitive_deps,
                    }

    if fp_links:
        defs_bzl_header.append("""load("@aspect_rules_js//npm/private:npm_link_package.bzl",
    _npm_link_package_store = "npm_link_package_store",
    _npm_link_package_direct = "npm_link_package_direct")""")

    defs_bzl_body = [
        """def npm_link_all_packages(name = "node_modules", imported_links = []):
    \"\"\"Generated list of npm_link_package() target generators and first-party linked packages corresponding to the packages in @{pnpm_lock_wksp}{pnpm_lock}

    Args:
        name: name of catch all target to generate for all packages linked
        imported_links: optional list link functions from manually imported packages
            that were fetched with npm_import rules,

            For example,

            ```
            load("@npm//:defs.bzl", "npm_link_all_packages")
            load("@npm_meaning-of-life__links//:defs.bzl", npm_link_meaning_of_life = "npm_link_imported_package")

            npm_link_all_packages(
                name = "node_modules",
                imported_links = [
                    npm_link_meaning_of_life,
                ],
            )```
    \"\"\"

    root_package = "{root_package}"
    direct_packages = {direct_packages}
    is_root = native.package_name() == root_package
    is_direct = native.package_name() in direct_packages
    if not is_root and not is_direct:
        msg = "The npm_link_all_packages() macro loaded from {defs_bzl_file} and called in bazel package '%s' may only be called in the bazel package(s) corresponding to the root package '{root_package}' and packages [{direct_packages_comma_separated}]" % native.package_name()
        fail(msg)
    direct_targets = []
    scoped_direct_targets = {{}}

    for link_fn in imported_links:
        new_direct_targets, new_scoped_targets = link_fn(name)
        direct_targets.extend(new_direct_targets)
        for _scope, _targets in new_scoped_targets.items():
            scoped_direct_targets[_scope] = scoped_direct_targets[_scope] + _targets if _scope in scoped_direct_targets else _targets
""".format(
            pnpm_lock_wksp = str(rctx.attr.pnpm_lock.workspace_name),
            pnpm_lock = str(rctx.attr.pnpm_lock),
            root_package = root_package,
            direct_packages = str(direct_packages),
            direct_packages_comma_separated = "'" + "', '".join(direct_packages) + "'" if len(direct_packages) else "",
            defs_bzl_file = "@{}//:{}".format(rctx.name, _DEFS_BZL_FILENAME),
        ),
    ]

    root_links_bzl = []
    direct_links_bzl = {}
    for (i, _import) in enumerate(npm_imports):
        maybe_integrity = """
        integrity = "%s",""" % _import.integrity if _import.integrity else ""
        maybe_url = """
        url = "%s",""" % _import.url if _import.url else ""
        maybe_deps = ("""
        deps = %s,""" % starlark_codegen_utils.to_dict_attr(_import.deps, 2)) if len(_import.deps) > 0 else ""
        maybe_transitive_closure = ("""
        transitive_closure = %s,""" % starlark_codegen_utils.to_dict_list_attr(_import.transitive_closure, 2)) if len(_import.transitive_closure) > 0 else ""
        maybe_patches = ("""
        patches = %s,""" % _import.patches) if len(_import.patches) > 0 else ""
        maybe_patch_args = ("""
        patch_args = %s,""" % _import.patch_args) if len(_import.patches) > 0 and len(_import.patch_args) > 0 else ""
        maybe_custom_postinstall = ("""
        custom_postinstall = \"%s\",""" % _import.custom_postinstall) if _import.custom_postinstall else ""
        maybe_run_lifecycle_hooks = ("""
        run_lifecycle_hooks = True,""") if _import.run_lifecycle_hooks else ""

        repositories_bzl.append(_NPM_IMPORT_TMPL.format(
            link_packages = starlark_codegen_utils.to_dict_attr(_import.link_packages, 2, quote_value = False),
            link_workspace = rctx.attr.pnpm_lock.workspace_name,
            maybe_custom_postinstall = maybe_custom_postinstall,
            maybe_deps = maybe_deps,
            maybe_integrity = maybe_integrity,
            maybe_patch_args = maybe_patch_args,
            maybe_patches = maybe_patches,
            maybe_run_lifecycle_hooks = maybe_run_lifecycle_hooks,
            maybe_transitive_closure = maybe_transitive_closure,
            maybe_url = maybe_url,
            name = _import.name,
            package = _import.package,
            root_package = _import.root_package,
            version = _import.version,
        ))

        if _import.link_packages:
            defs_bzl_header.append(
                """load("@{repo_name}{links_repo_suffix}//:defs.bzl", link_{i}_direct = "npm_link_imported_package_direct", link_{i}_store = "npm_link_imported_package_store")""".format(
                    i = i,
                    repo_name = _import.name,
                    links_repo_suffix = utils.links_repo_suffix,
                ),
            )
        else:
            defs_bzl_header.append(
                """load("@{repo_name}{links_repo_suffix}//:defs.bzl", link_{i}_store = "npm_link_imported_package_store")""".format(
                    i = i,
                    repo_name = _import.name,
                    links_repo_suffix = utils.links_repo_suffix,
                ),
            )

        root_links_bzl.append("""        link_{i}_store(name = "{{}}/{name}".format(name))""".format(
            i = i,
            name = _import.package,
        ))
        for link_package, _link_aliases in _import.link_packages.items():
            link_aliases = _link_aliases or [_import.package]
            for link_alias in link_aliases:
                if link_package not in direct_links_bzl:
                    direct_links_bzl[link_package] = []
                direct_links_bzl[link_package].append("""            direct_targets.append(link_{i}_direct(name = "{{}}/{name}".format(name)))""".format(
                    i = i,
                    name = link_alias,
                ))
                if len(link_alias.split("/", 1)) > 1:
                    package_scope = link_alias.split("/", 1)[0]
                    direct_links_bzl[link_package].append("""            scoped_direct_targets["{package_scope}"] = scoped_direct_targets["{package_scope}"] + [direct_targets[-1]] if "{package_scope}" in scoped_direct_targets else [direct_targets[-1]]""".format(
                        package_scope = package_scope,
                    ))

        for link_package in _import.link_packages.keys():
            # Generate a package_json.bzl file for the bin entries (even if there are none)
            # Note, there's no has_bin attribute on npm_import so we can't get the boolean
            # value from the _import struct.
            # If this is a problem, we could lookup into the packages again like
            # if lockfile.get("packages").values()[i].get("hasBin"):
            if True:
                build_file_path = paths.normalize(paths.join(link_package, _import.package, "BUILD.bazel"))
                rctx.file(build_file_path, "\n".join(generated_by_lines))
                package_json_bzl_file_path = paths.normalize(paths.join(link_package, _import.package, _PACKAGE_JSON_BZL_FILENAME))
                repo_package_json_bzl = paths.normalize(paths.join(link_package, _PACKAGE_JSON_BZL_FILENAME)).rsplit("/", 1)
                if len(repo_package_json_bzl) == 1:
                    repo_package_json_bzl = [""] + repo_package_json_bzl
                repo_package_json_bzl = ":".join(repo_package_json_bzl)
                rctx.file(package_json_bzl_file_path, "\n".join([
                    _BIN_TMPL.format(
                        repo_package_json_bzl = repo_package_json_bzl,
                        repo_name = _import.name,
                    ),
                ]))

    defs_bzl_body.append("""    if is_root:""")
    defs_bzl_body.extend(root_links_bzl)

    defs_bzl_body.append("""    if is_direct:""")
    for link_package, bzl in direct_links_bzl.items():
        defs_bzl_body.append("""        if native.package_name() == "{}":""".format(link_package))
        defs_bzl_body.extend(bzl)

    for fp_link in fp_links.values():
        fp_package = fp_link.get("package")
        fp_path = fp_link.get("path")
        fp_link_packages = fp_link.get("link_packages")
        fp_deps = fp_link.get("deps")
        fp_bazel_name = utils.bazel_name(fp_package, fp_path)
        fp_target = "//{}:{}".format(fp_path, paths.basename(fp_path))

        defs_bzl_body.append(_FP_STORE_TMPL.format(
            bazel_name = fp_bazel_name,
            deps = starlark_codegen_utils.to_dict_attr(fp_deps, 3, quote_key = False),
            npm_package_target = fp_target,
            package = fp_package,
        ))

        defs_bzl_body.append(_FP_DIRECT_TMPL.format(
            bazel_name = fp_bazel_name,
            link_packages = fp_link_packages.keys(),
            name = fp_package,
            package = fp_package,
            package_directory_output_group = utils.package_directory_output_group,
            root_package = root_package,
        ))

        if len(fp_package.split("/", 1)) > 1:
            package_scope = fp_package.split("/", 1)[0]
            defs_bzl_body.append("""            scoped_direct_targets["{package_scope}"] = scoped_direct_targets["{package_scope}"] + [direct_targets[-1]] if "{package_scope}" in scoped_direct_targets else [direct_targets[-1]]""".format(
                package_scope = package_scope,
            ))

    # Generate catch all & scoped npm_linked_packages target
    defs_bzl_body.append("""
    for scope, scoped_targets in scoped_direct_targets.items():
        npm_linked_packages(
            name = "{}/{}".format(name, scope),
            srcs = scoped_targets,
            tags = ["manual"],
            visibility = ["//visibility:public"],
        )

    npm_linked_packages(
        name = name,
        srcs = direct_targets,
        tags = ["manual"],
        visibility = ["//visibility:public"],
    )""")

    rctx.file(_DEFS_BZL_FILENAME, "\n".join(defs_bzl_header + [""] + defs_bzl_body + [""]))
    rctx.file(_REPOSITORIES_BZL_FILENAME, "\n".join(repositories_bzl))
    rctx.file("BUILD.bazel", "\n".join(generated_by_lines + [
        "exports_files({})".format(starlark_codegen_utils.to_list_attr([
            _DEFS_BZL_FILENAME,
            _REPOSITORIES_BZL_FILENAME,
        ])),
    ]))

npm_translate_lock = struct(
    doc = _DOC,
    implementation = _impl,
    attrs = _ATTRS,
    gen_npm_imports = _gen_npm_imports,
)

npm_translate_lock_testonly = struct(
    testonly_process_lockfile = _process_lockfile,
)
