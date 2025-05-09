{ cudaLib, lib }:
let
  inherit (builtins)
    deepSeq
    genericClosure
    getContext
    tryEval
    typeOf
    unsafeDiscardStringContext
    ;
  inherit (cudaLib.data) redistUrlPrefix;
  inherit (cudaLib.utils)
    attrPaths
    dotsToUnderscores
    dropDots
    drvAttrPathsStrategy
    drvAttrPathsStrategyImpl
    flattenAttrs
    mkCmakeCudaArchitecturesString
    mkFailedAssertionsString
    mkGencodeFlag
    mkOptions
    mkRealArchitecture
    mkVirtualArchitecture
    packagesFromDirectoryRecursive'
    trimComponents
    ;
  inherit (lib) addErrorContext;
  inherit (lib.asserts) assertMsg;
  inherit (lib.attrsets)
    attrNames
    attrValues
    catAttrs
    filterAttrs
    getAttr
    getAttrFromPath
    hasAttr
    isAttrs
    isDerivation
    listToAttrs
    mapAttrs
    mapAttrs'
    nameValuePair
    showAttrPath
    ;
  inherit (lib.debug) traceIf;
  inherit (lib.fixedPoints) makeExtensible;
  inherit (lib.lists)
    concatMap
    findFirst
    foldl'
    head
    last
    map
    naturalSort
    optionals
    take
    unique
    ;
  inherit (lib.options) mkOption;
  inherit (lib.strings)
    concatMapStringsSep
    concatStringsSep
    hasSuffix
    optionalString
    replaceStrings
    versionAtLeast
    ;
  inherit (lib.trivial)
    const
    flip
    id
    pipe
    warnIf
    ;
  inherit (lib.versions) major splitVersion;
in
{
  /**
    Maps `mkOption` over the values of an attribute set.

    # Type

    ```
    mkOptions :: (attrs :: AttrSet) -> AttrSet
    ```

    # Inputs

    `attrs`

    : The attribute set to map over
  */
  mkOptions = mapAttrs (const mkOption);

  /**
    Creates an options module from an attribute set of options by mapping `mkOption` over the values of the attribute
    set.

    # Type

    ```
    mkOptionsModule :: (attrs :: AttrSet) -> AttrSet
    ```

    # Inputs

    `attrs`

    : An attribute set
  */
  mkOptionsModule = attrs: { options = mkOptions attrs; };

  /**
    Function to generate a URL for something in the redistributable tree.

    # Type

    ```
    mkRedistUrl :: (redistName :: RedistName) -> (relativePath :: NonEmptyStr) -> RedistUrl
    ```

    # Inputs

    `redistName`

    : The name of the redistributable

    `relativePath`

    : The relative path to a file in the redistributable tree
  */
  mkRedistUrl =
    redistName: relativePath:
    concatStringsSep "/" (
      [
        redistUrlPrefix
      ]
      ++ (
        if redistName != "tensorrt" then
          [
            redistName
            "redist"
          ]
        else
          [ "machine-learning" ]
      )
      ++ [
        relativePath
      ]
    );

  /**
    Function to recreate a relative path for a redistributable.

    # Type

    ```
    mkRedistUrlRelativePath
      :: { cudaVariant :: CudaVariant
         , packageName :: PackageName
         , redistSystem :: RedistSystem
         , redistName :: RedistName
         , relativePath :: NullOr NonEmptyStr
         , releaseInfo :: ReleaseInfo
         }
      -> String
    ```

    # Inputs

    `cudaVariant`

    : The CUDA variant of the package

    `packageName`

    : The name of the package

    `redistSystem`

    : The redist system of the package

    `redistName`

    : The name of the redistributable

    `relativePath`

    : An optional relative path to the redistributable, defaults to null

    `releaseInfo`

    : The release information of the package
  */
  mkRedistUrlRelativePath =
    {
      cudaVariant,
      packageName,
      redistSystem,
      redistName,
      relativePath ? null,
      releaseInfo,
    }:
    if relativePath != null then
      relativePath
    else
      assert assertMsg (redistName != "tensorrt")
        "mkRedistUrlRelativePath: tensorrt does not use standard naming conventions for relative paths and requires relativePath be non-null";
      concatStringsSep "/" [
        packageName
        redistSystem
        (concatStringsSep "-" [
          packageName
          redistSystem
          (releaseInfo.version + (if cudaVariant != "None" then "_${cudaVariant}" else ""))
          "archive.tar.xz"
        ])
      ];

  mkFailedAssertionsString = foldl' (
    failedAssertionsString:
    { assertion, message }:
    failedAssertionsString + optionalString (!assertion) ("\n- " + message)
  ) "";

  /**
    Evaluate assertions and add error context to return value.

    # Type

    ```
    evaluateAssertions
      :: (assertions :: List { assertion :: Bool, message :: String })
      -> Bool
    ```
  */
  evaluateAssertions =
    assertions:
    let
      failedAssertionsString = mkFailedAssertionsString assertions;
      hasNoFailedAssertions = failedAssertionsString == "";
    in
    (
      if hasNoFailedAssertions then
        id
      else
        addErrorContext "with failed assertions:${failedAssertionsString}"
    )
      hasNoFailedAssertions;

  /**
    Returns a boolean indicating whether the package is broken as a result of `finalAttrs.passthru.brokenAssertions`,
    optionally logging evaluation warnings for each reason.

    NOTE: This function requires `finalAttrs.passthru.brokenAssertions` to be a list of assertions and
    `finalAttrs.finalPackage.name` to be available.

    # Type

    ```
    mkMetaBroken :: (warn :: Bool) -> (finalAttrs :: AttrSet) -> Bool
    ```

    # Inputs

    `warn`

    : A boolean indicating whether to log warnings

    `finalAttrs`

    : The final attributes of the package
  */
  mkMetaBroken =
    warn: finalAttrs:
    let
      failedAssertionsString = mkFailedAssertionsString finalAttrs.passthru.brokenAssertions;
      hasFailedAssertions = failedAssertionsString != "";
    in
    warnIf (warn && hasFailedAssertions)
      "Package ${finalAttrs.finalPackage.name} is marked as broken due to the following failed assertions:${failedAssertionsString}"
      hasFailedAssertions;

  /**
    Returns a list of bad platforms for a given package if assertsions in `finalAttrs.passthru.platformAssertions` fail,
    optionally logging evaluation warnings for each reason.

    NOTE: This function requires `finalAttrs.passthru.platformAssertions` to be a list of assertions and
    `finalAttrs.finalPackage.name` and `finalAttrs.finalPackage.stdenv` to be available.

    # Type

    ```
    mkMetaBadPlatforms :: (warn :: Bool) -> (finalAttrs :: AttrSet) -> List String
    ```
  */
  mkMetaBadPlatforms =
    warn: finalAttrs:
    let
      failedAssertionsString = mkFailedAssertionsString finalAttrs.passthru.platformAssertions;
      hasFailedAssertions = failedAssertionsString != "";
      finalStdenv = finalAttrs.finalPackage.stdenv;
    in
    warnIf (warn && hasFailedAssertions)
      "Package ${finalAttrs.finalPackage.name} is unsupported on this platform due to the following failed assertions:${failedAssertionsString}"
      (
        optionals hasFailedAssertions (unique [
          finalStdenv.buildPlatform.system
          finalStdenv.hostPlatform.system
          finalStdenv.targetPlatform.system
        ])
      );

  /**
    A variant of `packagesFromDirectoryRecursive` which takes positional arguments and wraps the result of the
    directory traversal in a `recurseIntoAttrs` call.

    NOTE: This function is largely taken from
    https://github.com/NixOS/nixpkgs/blob/eb82888147a6aecb8ae6ee5a685ecdf021b8ed33/lib/filesystem.nix#L385-L416

    # Type

    ```
    packagesFromDirectoryRecursive'
      :: (callPackage :: Path | (AttrSet -> AttrSet) -> AttrSet)
      -> (directory :: Path)
      -> AttrSet
    ```

    # Inputs

    `callPackage`

    : A function to call on the leaves of the directory traversal which matches the signature of `callPackage`.

    `directory`

    : The directory to recurse into
  */
  packagesFromDirectoryRecursive' =
    callPackage: directory:
    let
      inherit (lib) concatMapAttrs recurseIntoAttrs removeSuffix;
      inherit (lib.path) append;
      defaultPath = append directory "package.nix";
    in
    if builtins.pathExists defaultPath then
      # if `${directory}/package.nix` exists, call it directly
      callPackage defaultPath { }
    else
      recurseIntoAttrs (
        concatMapAttrs (
          name: type:
          # otherwise, for each directory entry
          let
            path = append directory name;
          in
          if type == "directory" then
            # recurse into directories
            { ${name} = packagesFromDirectoryRecursive' callPackage path; }
          else if type == "regular" && hasSuffix ".nix" name then
            # call .nix files
            { ${removeSuffix ".nix" name} = callPackage path { }; }
          else if type == "regular" then
            # ignore non-nix files
            { }
          else
            throw ''
              lib.filesystem.packagesFromDirectoryRecursive: Unsupported file type ${type} at path ${toString path}
            ''
        ) (builtins.readDir directory)
      );

  /**
    Maps a NVIDIA redistributable system to Nix systems.

    NOTE: This function returns a list of systems because the redistributable systems `"linux-all"` and
    `"source"` can be built on multiple systems.

    NOTE: This function *will* be called by unsupported systems because `cudaPackages` is part of
    `all-packages.nix`, which is evaluated on all systems. As such, we need to handle unsupported
    systems gracefully.

    # Type

    ```
    getNixSystems :: (redistSystem :: RedistSystem) -> [String]
    ```

    # Inputs

    `redistSystem`

    : The NVIDIA redistributable system

    # Examples

    :::{.example}
    ## `cudaLib.utils.getNixSystems` usage examples

    ```nix
    getNixSystems "linux-sbsa"
    => [ "aarch64-linux" ]
    ```

    ```nix
    getNixSystems "linux-aarch64"
    => [ "aarch64-linux" ]
    ```
    :::
  */
  getNixSystems =
    redistSystem:
    if redistSystem == "linux-x86_64" then
      [ "x86_64-linux" ]
    else if redistSystem == "linux-sbsa" || redistSystem == "linux-aarch64" then
      [ "aarch64-linux" ]
    else if redistSystem == "linux-all" || redistSystem == "source" then
      [
        "aarch64-linux"
        "x86_64-linux"
      ]
    else
      [ ];

  /**
    Function to map Nix system to NVIDIA redist arch

    NOTE: We swap out the default `linux-sbsa` redist (for server-grade ARM chips) with the
    `linux-aarch64` redist (which is for Jetson devices) if we're building any Jetson devices.
    Since both are based on aarch64, we can only have one or the other, otherwise there's an
    ambiguity as to which should be used.

    NOTE: This function *will* be called by unsupported systems because `cudaPackages` is part of
    `all-packages.nix`, which is evaluated on all systems. As such, we need to handle unsupported
    systems gracefully.

    # Type

    ```
    getRedistSystem :: (hasJetsonCudaCapability :: Bool) -> (nixSystem :: String) -> String
    ```

    # Inputs

    `hasJetsonCudaCapability`

    : If configured for a Jetson device

    `nixSystem`

    : The Nix system

    # Examples

    :::{.example}
    ## `cudaLib.utils.getRedistSystem` usage examples

    ```nix
    getRedistSystem true "aarch64-linux"
    => "linux-aarch64"
    ```

    ```nix
    getRedistSystem false "aarch64-linux"
    => "linux-sbsa"
    ```
    :::
  */
  getRedistSystem =
    hasJetsonCudaCapability: nixSystem:
    if nixSystem == "x86_64-linux" then
      "linux-x86_64"
    else if nixSystem == "aarch64-linux" then
      if hasJetsonCudaCapability then "linux-aarch64" else "linux-sbsa"
    else
      "unsupported";

  /**
    Returns a boolean indicating whether the provided redistSystem is supported by any of the redist systems.
  */
  redistSystemIsSupported =
    redistSystem: redistSystems:
    findFirst (
      redistSystem':
      redistSystem' == redistSystem || redistSystem' == "linux-all" || redistSystem' == "source"
    ) null redistSystems != null;

  /**
    Returns whether a capability should be built by default for a particular CUDA version.

    Capabilities built by default are baseline, non-Jetson capabilities with relatively recent CUDA support.

    # Type

    ```
    cudaCapabilityIsDefault
      :: (cudaMajorMinorVersion :: Version)
      -> (cudaCapabilityInfo :: CudaCapabilityInfo)
      -> Bool
    ```

    # Inputs

    `cudaMajorMinorVersion`

    : The CUDA version to check

    `cudaCapabilityInfo`

    : The capability information to check
  */
  cudaCapabilityIsDefault =
    cudaMajorMinorVersion: cudaCapabilityInfo:
    let
      recentCapability =
        cudaCapabilityInfo.dontDefaultAfterCudaMajorMinorVersion == null
        || versionAtLeast cudaCapabilityInfo.dontDefaultAfterCudaMajorMinorVersion cudaMajorMinorVersion;
    in
    recentCapability
    && !cudaCapabilityInfo.isJetson
    && !cudaCapabilityInfo.isArchitectureSpecific
    && !cudaCapabilityInfo.isFamilySpecific;

  /**
    Returns whether a capability is supported for a particular CUDA version.

    # Type

    ```
    cudaCapabilityIsSupported
      :: (cudaMajorMinorVersion :: Version)
      -> (cudaCapabilityInfo :: CudaCapabilityInfo)
      -> Bool
    ```

    # Inputs

    `cudaMajorMinorVersion`

    : The CUDA version to check

    `cudaCapabilityInfo`

    : The capability information to check
  */
  cudaCapabilityIsSupported =
    cudaMajorMinorVersion: cudaCapabilityInfo:
    let
      lowerBoundSatisfied = versionAtLeast cudaMajorMinorVersion cudaCapabilityInfo.minCudaMajorMinorVersion;
      upperBoundSatisfied =
        (cudaCapabilityInfo.maxCudaMajorMinorVersion == null)
        || (versionAtLeast cudaCapabilityInfo.maxCudaMajorMinorVersion cudaMajorMinorVersion);
    in
    lowerBoundSatisfied && upperBoundSatisfied;

  /**
    Generates a CUDA variant name from a version.

    # Type

    ```
    mkCudaVariant :: (version :: String) -> String
    ```

    # Inputs

    `version`

    : The version string

    # Examples

    :::{.example}
    ## `cudaLib.utils.mkCudaVariant` usage examples

    ```nix
    mkCudaVariant "11.0"
    => "cuda11"
    ```
    :::
  */
  mkCudaVariant = version: "cuda${major version}";

  /**
    Utility function to generate assertions for missing packages.

    Used to mark a package as unsupported if any of its required packages are missing (null).

    Expects a set of attributes.

    Most commonly used in overrides files on a callPackage-provided attribute set of packages.

    NOTE: We typically use platfromAssertions instead of brokenAssertions because the presence of packages set to null
    means evaluation will fail if package attributes are accessed without checking for null first. OfBorg
    evaluation sets allowBroken to true, which means we can't rely on brokenAssertions to prevent evaluation of
    a package with missing dependencies.

    # Type

    ```
    mkMissingPackagesAssertions
      :: (attrs :: AttrSet)
      -> (assertions :: List { assertion :: Bool, message :: String })
    ```

    # Inputs

    `attrs`

    : The attributes to check for null

    # Examples

    :::{.example}
    ## `cudaLib.utils.mkMissingPackagesAssertions` usage examples

    ```nix
    {
      lib,
      libcal ? null,
      libcublas,
      utils,
    }:
    let
      inherit (lib.attrsets) recursiveUpdate;
      inherit (cudaLib.utils) mkMissingPackagesAssertions;
    in
    prevAttrs: {
      passthru = prevAttrs.passthru or { } // {
        platformAssertions =
          prevAttrs.passthru.platformAssertions or [ ]
          ++ mkMissingPackagesAssertions { inherit libcal; };
      };
    }
    ```
    :::
  */
  mkMissingPackagesAssertions = flip pipe [
    # Take the attributes that are null.
    (filterAttrs (_: value: value == null))
    attrNames
    # Map them to assertions.
    (map (name: {
      message = "${name} is available";
      assertion = false;
    }))
  ];

  /**
    Replaces dots in a string with underscores.

    # Type

    ```
    dotsToUnderscores :: (str :: String) -> String
    ```

    # Inputs

    `str`

    : The string for which dots shall be replaced by underscores

    # Examples

    :::{.example}
    ## `cudaLib.utils.dotsToUnderscores` usage examples

    ```nix
    dotsToUnderscores "1.2.3"
    => "1_2_3"
    ```
    :::
  */
  dotsToUnderscores = replaceStrings [ "." ] [ "_" ];

  /**
    Create a versioned CUDA package set name from a CUDA version.

    # Type

    ```
    mkCudaPackagesVersionedName :: (cudaVersion :: Version) -> String
    ```

    # Inputs

    `cudaVersion`

    : The CUDA version to use

    # Examples

    :::{.example}
    ## `cudaLib.utils.mkCudaPackagesVersionedName` usage examples

    ```nix
    mkCudaPackagesVersionedName "1.2.3"
    => "cudaPackages_1_2_3"
    ```
    :::
  */
  mkCudaPackagesVersionedName = cudaVersion: "cudaPackages_${dotsToUnderscores cudaVersion}";

  /**
    Map over an attribute set, applying a function to each attribute name and value.

    # Type

    ```
    bimap
      :: (nameFunc :: String -> String)
      -> (valueFunc :: Any -> Any)
      -> (attrs :: AttrSet)
      -> AttrSet
    ```

    # Inputs

    `nameFunc`

    : A function to apply to each attribute name

    `valueFunc`

    : A function to apply to each attribute value

    `attrs`

    : The attribute set to map over
  */
  bimap =
    nameFunc: valueFunc: mapAttrs' (name: value: nameValuePair (nameFunc name) (valueFunc value));

  /**
    TODO:
  */
  mkCmakeCudaArchitecturesString = concatMapStringsSep ";" dropDots;

  /**
    TODO:
  */
  mkGencodeFlag =
    archPrefix: cudaCapability:
    let
      cap = dropDots cudaCapability;
    in
    "-gencode=arch=compute_${cap},code=${archPrefix}_${cap}";

  /**
    TODO:
  */
  mkRealArchitecture = cudaCapability: "sm_" + dropDots cudaCapability;

  /**
    TODO:
  */
  mkVirtualArchitecture = cudaCapability: "compute_" + dropDots cudaCapability;

  /**
    Removes the dots from a string.

    # Type

    ```
    dropDots :: (str :: String) -> String
    ```

    # Inputs

    `str`

    : The string to remove dots from

    # Examples

    :::{.example}
    ## `cudaLib.utils.dropDots` usage examples

    ```nix
    dropDots "1.2.3"
    => "123"
    ```
    :::
  */
  dropDots = replaceStrings [ "." ] [ "" ];

  /**
    Extracts the major, minor, and patch version from a string.

    # Type

    ```
    majorMinorPatch :: (version :: String) -> String
    ```

    # Inputs

    `version`

    : The version string

    # Examples

    :::{.example}
    ## `cudaLib.utils.majorMinorPatch` usage examples

    ```nix
    majorMinorPatch "11.0.3.4"
    => "11.0.3"
    ```
    :::
  */
  majorMinorPatch = trimComponents 3;

  /**
    Get a version string with no more than than the specified number of components.

    # Type

    ```
    trimComponents :: (numComponents :: Integer) -> (version :: String) -> String
    ```

    # Inputs

    `numComponents`
    : A positive integer corresponding to the maximum number of components to keep

    `version`
    : A version string

    # Examples

    :::{.example}
    ## `cudaLib.utils.trimComponents` usage examples

    ```nix
    trimComponents 1 "1.2.3.4"
    => "1"
    ```

    ```nix
    trimComponents 3 "1.2.3.4"
    => "1.2.3"
    ```

    ```nix
    trimComponents 9 "1.2.3.4"
    => "1.2.3.4"
    ```
    :::
  */
  trimComponents =
    n: v:
    pipe v [
      splitVersion
      (take n)
      (concatStringsSep ".")
    ];

  /**
    Produces a list of attribute paths for a given attribute set.

    # Type

    ```
    attrPaths :: { includeCond :: [String] -> Any -> Bool
                 , recurseCond :: [String] -> Any -> Bool
                 , doTrace :: Bool = false
                 }
              -> (attrs :: AttrSet)
              -> [[String]]
    ```

    # Inputs

    `includeCond`

    : A function that takes an attribute path and a value and returns a boolean, controlling whether the attribute
      path should be included in the output.

    `recurseCond`

    : A function that takes an attribute path and a value and returns a boolean, controlling whether the attribute
      path should be recursed into.

    `doTrace`

    : A boolean controlling whether to print debug information.
      Defaults to `false`.

    `attrs`

    : The attribute set to generate attribute paths for.
  */
  attrPaths =
    {
      includeCond,
      recurseCond,
      doTrace ? false,
    }:
    let
      maybeTrace = traceIf doTrace;
      go =
        parentAttrPath: parentAttrs:
        concatMap (
          name:
          let
            attrPath = parentAttrPath ++ [ name ];
            value = getAttr name parentAttrs;
            include = includeCond attrPath value;
            recurse = recurseCond attrPath value;
          in
          (
            if include then
              maybeTrace "cudaLib.utils.attrPaths: including attribute ${showAttrPath attrPath}" [ attrPath ]
            else
              maybeTrace "cudaLib.utils.attrPaths: excluding attribute ${showAttrPath attrPath}" [ ]
          )
          ++ (
            if recurse then
              maybeTrace "cudaLib.utils.attrPaths: recursing into attribute ${showAttrPath attrPath}" (
                go attrPath value
              )
            else
              maybeTrace "cudaLib.utils.attrPaths: not recursing into attribute ${showAttrPath attrPath}" [ ]
          )
        ) (attrNames parentAttrs);
    in
    attrs:
    assert assertMsg (isAttrs attrs) "cudaLib.utils.attrPaths: `attrs` must be an attribute set";
    go [ ] attrs;

  # Credit for this strategy goes to Adam Joseph and is taken from their work on
  # https://github.com/NixOS/nixpkgs/pull/269356.
  drvAttrPathsStrategyImpl = makeExtensible (final: {
    # No release package attrpath may have any of these attrnames as
    # its initial component.
    #
    # If you can find a way to remove any of these entries without
    # causing CI to fail, please do so.
    #
    excludeAtTopLevel = {
      AAAAAASomeThingsFailToEvaluate = null;

      #  spliced packagesets
      __splicedPackages = null;
      pkgsBuildBuild = null;
      pkgsBuildHost = null;
      pkgsBuildTarget = null;
      pkgsHostHost = null;
      pkgsHostTarget = null;
      pkgsTargetTarget = null;
      buildPackages = null;
      targetPackages = null;

      # cross packagesets
      pkgsLLVM = null;
      pkgsMusl = null;
      pkgsStatic = null;
      pkgsCross = null;
      pkgsx86_64Darwin = null;
      pkgsi686Linux = null;
      pkgsLinux = null;
      pkgsExtraHardening = null;
    };

    # No release package attrname may have any of these at a component
    # anywhere in its attrpath.  These are the names of gigantic
    # top-level attrsets that have leaked into so many sub-packagesets
    # that it's easier to simply exclude them entirely.
    #
    # If you can find a way to remove any of these entries without
    # causing CI to fail, please do so.
    #
    excludeAtAnyLevel = {
      lib = null;
      override = null;
      __functor = null;
      __functionArgs = null;
      __splicedPackages = null;
      newScope = null;
      scope = null;
      pkgs = null;
      callPackage = null;
      mkDerivation = null;
      overrideDerivation = null;
      overrideScope = null;
      overrideScope' = null;

      # Special case: lib/types.nix leaks into a lot of nixos-related
      # derivations, and does not eval deeply.
      type = null;
    };

    isExcluded =
      attrPath:
      hasAttr (head attrPath) final.excludeAtTopLevel || hasAttr (last attrPath) final.excludeAtAnyLevel;

    # Include the attribute so long as it has a non-null drvPath.
    # NOTE: We must wrap with `tryEval` and `deepSeq` to catch values which are just `throw`s.
    # NOTE: Do not use `meta.available` because it does not (by default) recursively check dependencies, and requires
    # an undocumented config option (checkMetaRecursively) to do so:
    # https://github.com/NixOS/nixpkgs/blob/master/pkgs/stdenv/generic/check-meta.nix#L496
    # The best we can do is try to compute the drvPath and see if it throws.
    # What we really need is something like:
    # https://github.com/NixOS/nixpkgs/pull/245322
    includeCond =
      attrPath: value:
      let
        unsafeTest = isDerivation value && value.drvPath or null != null;
        attempt = tryEval (deepSeq unsafeTest unsafeTest);
      in
      !(final.isExcluded attrPath) && attempt.success && attempt.value;

    # Recurse when recurseForDerivations is not set.
    recurseByDefault = false;

    # Recurse so long as the attribute set:
    # - is not a derivation or set __recurseIntoDerivationForReleaseJobs set to true
    # - set recurseForDerivations to true or recurseForDerivations is not set and recurseByDefault is true
    # - does not set __attrsFailEvaluation to true
    # NOTE: We must wrap with `tryEval` and `deepSeq` to catch values which are just `throw`s.
    recurseCond =
      attrPath: value:
      let
        unsafeTest =
          isAttrs value
          && (!(isDerivation value) || value.__recurseIntoDerivationForReleaseJobs or false)
          && value.recurseForDerivations or final.recurseByDefault
          && !(value.__attrsFailEvaluation or false);
        attempt = tryEval (deepSeq unsafeTest unsafeTest);
      in
      !(final.isExcluded attrPath) && attempt.success && attempt.value;
  });

  drvAttrPathsStrategy = {
    inherit (drvAttrPathsStrategyImpl) includeCond recurseCond;
  };

  drvAttrPathsRecurseByDefaultStrategy = {
    inherit (drvAttrPathsStrategyImpl.extend (_: _: { recurseByDefault = true; }))
      includeCond
      recurseCond
      ;
  };

  /**
    TODO: Work on docs.

    # Type

    ```
    flattenAttrs :: { includeCond :: [String] -> Any -> Bool
                    , recurseCond :: [String] -> Any -> Bool
                    , doTrace :: Bool = false
                    }
                 -> (attrs :: AttrSet)
                 -> AttrSet
    ```

    # Inputs

    `includeCond`

    : A function that takes an attribute path and a value and returns a boolean, controlling whether the value
      should be included in the output.

    `recurseCond`

    : A function that takes an attribute path and a value and returns a boolean, controlling whether the value
      should be recursed into.

    `doTrace`

    : A boolean controlling whether to print debug information.
      Defaults to `false`.

    `attrs`

    : The attribute set to generate attribute paths for.
  */
  flattenAttrs =
    strategy: attrs:
    pipe attrs [
      (attrPaths strategy)
      (map (attrPath: nameValuePair (showAttrPath attrPath) (getAttrFromPath attrPath attrs)))
      listToAttrs
    ];

  /**
    TODO: Work on docs.

    # Type

    ```
    flattenDrvTree :: (attrs :: AttrSet) -> AttrSet
    ```

    # Inputs

    `attrs`

    : The attribute set to flatten.
  */
  flattenDrvTree = flattenAttrs drvAttrPathsStrategy;

  # TODO: Docs
  collectDepsRecursive =
    let
      mkItem = dep: {
        # String interpolation is easier than dep.outPath with a fallback to "${dep}" in the case of a path or string with context.
        key = unsafeDiscardStringContext "${dep}";
        inherit dep;
      };

      # listStrategy :: List Any -> List (Derivation | Path)
      listStrategy = concatMap getDepsFromValueSingleStep;
      # Attribute names can't be paths or strings with context.
      # setStrategy :: Attrs Any -> List (Derivation | Path)
      setStrategy = attrs: if isDerivation attrs then [ attrs ] else listStrategy (attrValues attrs);
      # stringStrategy :: String -> List Path
      stringStrategy = string: attrNames (getContext string);
      # pathStrategy :: Path -> List Path
      pathStrategy = path: [ path ];
      # fallbackStrategy :: a -> List (Derivation | Path)
      fallbackStrategy = const [ ];

      strategies = {
        list = listStrategy;
        set = setStrategy;
        string = stringStrategy;
        path = pathStrategy;
      };

      # getDrvsFromValueSingleStep :: a -> List (Derivation | Path)
      # type :: "int" | "bool" | "string" | "path" | "null" | "set" | "list" | "lambda" | "float"
      getDepsFromValueSingleStep = value: (strategies.${typeOf value} or fallbackStrategy) value;
    in
    drvs:
    catAttrs "dep" (genericClosure {
      startSet = map mkItem drvs;
      # If we don't have drvAttrs then it's not a derivation produced by mkDerivation and we can just return
      # since there's no further processing we can do.
      # NOTE: Processing drvAttrs is safer than trying to process the attribute set resulting from mkDerivation.
      operator =
        item:
        if item.dep ? drvAttrs then map mkItem (getDepsFromValueSingleStep item.dep.drvAttrs) else [ ];
    });

  # TODO: These docs are incorrect.

  # Flags are determined based on your CUDA toolkit by default.  You may benefit
  # from improved performance, reduced file size, or greater hardware support by
  # passing a configuration based on your specific GPU environment.
  #
  # cudaCapabilities :: List Capability
  # List of hardware generations to build.
  # E.g. [ "8.0" ]
  # Currently, the last item is considered the optional forward-compatibility arch,
  # but this may change in the future.
  #
  # cudaForwardCompat :: Bool
  # Whether to include the forward compatibility gencode (+PTX)
  # to support future GPU generations.
  # E.g. true
  #
  # Please see the accompanying documentation or https://github.com/NixOS/nixpkgs/pull/205351

  formatCapabilities =
    {
      cudaCapabilityToInfo,
      cudaCapabilities,
      cudaForwardCompat ? true,
    }:
    let
      # realArchs :: List String
      # The real architectures are physical architectures supported by the CUDA version.
      # E.g. [ "sm_75" "sm_86" ]
      realArchs = map mkRealArchitecture cudaCapabilities;

      # virtualArchs :: List String
      # The virtual architectures are typically used for forward compatibility, when trying to support
      # an architecture newer than the CUDA version allows.
      # E.g. [ "compute_75" "compute_86" ]
      virtualArchs = map mkVirtualArchitecture cudaCapabilities;

      # gencode :: List String
      # A list of CUDA gencode arguments to pass to NVCC.
      # E.g. [ "-gencode=arch=compute_75,code=sm_75" ... "-gencode=arch=compute_86,code=compute_86" ]
      gencode =
        let
          base = map (mkGencodeFlag "sm") cudaCapabilities;
          forward = mkGencodeFlag "compute" (last cudaCapabilities);
        in
        base ++ optionals cudaForwardCompat [ forward ];
    in
    {
      inherit
        cudaCapabilities
        cudaForwardCompat
        gencode
        realArchs
        virtualArchs
        ;

      # archNames :: List String
      # E.g. [ "Ampere" "Turing" ]
      archNames = pipe cudaCapabilities [
        (map (cudaCapability: cudaCapabilityToInfo.${cudaCapability}.archName))
        unique
        naturalSort
      ];

      # archs :: List String
      # By default, build for all supported architectures and forward compatibility via a virtual
      # architecture for the newest supported architecture.
      # E.g. [ "sm_75" "sm_86" "compute_86" ]
      archs = realArchs ++ optionals cudaForwardCompat [ (last virtualArchs) ];

      # gencodeString :: String
      # A space-separated string of CUDA gencode arguments to pass to NVCC.
      # E.g. "-gencode=arch=compute_75,code=sm_75 ... -gencode=arch=compute_86,code=compute_86"
      gencodeString = concatStringsSep " " gencode;

      # cmakeCudaArchitecturesString :: String
      # A semicolon-separated string of CUDA capabilities without dots, suitable for passing to CMake.
      # E.g. "75;86"
      cmakeCudaArchitecturesString = mkCmakeCudaArchitecturesString cudaCapabilities;
    };
}
