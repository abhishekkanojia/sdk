// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Classes and methods for enumerating and preparing tests.
///
/// This library includes:
///
/// - Creating tests by listing all the Dart files in certain directories,
///   and creating [TestCase]s for those files that meet the relevant criteria.
/// - Preparing tests, including copying files and frameworks to temporary
///   directories, and computing the command line and arguments to be run.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import "package:status_file/expectation.dart";

import 'browser.dart';
import 'command.dart';
import 'configuration.dart';
import 'expectation_set.dart';
import 'multitest.dart';
import 'path.dart';
import 'repository.dart';
import 'summary_report.dart';
import 'test_case.dart';
import 'test_configurations.dart';
import 'testing_servers.dart';
import 'utils.dart';

RegExp _multiHtmlTestGroupRegExp = RegExp(r"\s*[^/]\s*group\('[^,']*");
RegExp _multiHtmlTestRegExp = RegExp(r"useHtmlIndividualConfiguration\(\)");

/// Require at least one non-space character before '//[/#]'.
RegExp _multiTestRegExp = RegExp(r"\S *//[#/] \w+:(.*)");

typedef TestCaseEvent = void Function(TestCase testCase);

/// A simple function that tests [arg] and returns `true` or `false`.
typedef Predicate<T> = bool Function(T arg);

typedef CreateTest = void Function(Path filePath, Path originTestPath,
    {bool hasSyntaxError,
    bool hasCompileError,
    bool hasRuntimeError,
    bool hasStaticWarning,
    String multitestKey});

typedef VoidFunction = void Function();

/// Calls [function] asynchronously. Returns a future that completes with the
/// result of the function. If the function is `null`, returns a future that
/// completes immediately with `null`.
Future asynchronously<T>(T function()) {
  if (function == null) return Future<T>.value(null);

  var completer = Completer<T>();
  Timer.run(() => completer.complete(function()));

  return completer.future;
}

/// A completer that waits until all added [Future]s complete.
// TODO(rnystrom): Copied from web_components. Remove from here when it gets
// added to dart:core. (See #6626.)
class FutureGroup {
  static const _finished = -1;
  int _pending = 0;
  Completer<List> _completer = Completer();
  final List<Future> futures = [];
  bool wasCompleted = false;

  /// Wait for [task] to complete (assuming this barrier has not already been
  /// marked as completed, otherwise you'll get an exception indicating that a
  /// future has already been completed).
  void add(Future task) {
    if (_pending == _finished) {
      throw Exception("FutureFutureAlreadyCompleteException");
    }
    _pending++;
    var handledTaskFuture = task.catchError((e, StackTrace s) {
      if (!wasCompleted) {
        _completer.completeError(e, s);
        wasCompleted = true;
      }
    }).then((_) {
      _pending--;
      if (_pending == 0) {
        _pending = _finished;
        if (!wasCompleted) {
          _completer.complete(futures);
          wasCompleted = true;
        }
      }
    });
    futures.add(handledTaskFuture);
  }

  Future<List> get future => _completer.future;
}

/// A TestSuite represents a collection of tests.  It creates a [TestCase]
/// object for each test to be run, and passes the test cases to a callback.
///
/// Most TestSuites represent a directory or directory tree containing tests,
/// and a status file containing the expected results when these tests are run.
abstract class TestSuite {
  final TestConfiguration configuration;
  final String suiteName;
  final List<String> statusFilePaths;

  /// This function is set by subclasses before enqueueing starts.
  Function doTest;
  Map<String, String> _environmentOverrides;

  TestSuite(this.configuration, this.suiteName, this.statusFilePaths) {
    _environmentOverrides = {
      'DART_CONFIGURATION': configuration.configurationDirectory,
    };
    if (Platform.isWindows) {
      _environmentOverrides['DART_SUPPRESS_WER'] = '1';
      if (configuration.copyCoreDumps) {
        _environmentOverrides['DART_CRASHPAD_HANDLER'] =
            Path(buildDir + '/crashpad_handler.exe').absolute.toNativePath();
      }
    }
  }

  Map<String, String> get environmentOverrides => _environmentOverrides;

  /// The output directory for this suite's configuration.
  String get buildDir => configuration.buildDirectory;

  /// The path to the compiler for this suite's configuration. Returns `null` if
  /// no compiler should be used.
  String get compilerPath {
    var compilerConfiguration = configuration.compilerConfiguration;
    if (!compilerConfiguration.hasCompiler) return null;
    var name = compilerConfiguration.computeCompilerPath();

    // TODO(ahe): Only validate this once, in test_options.dart.
    TestUtils.ensureExists(name, configuration);
    return name;
  }

  /// Call the callback function onTest with a [TestCase] argument for each
  /// test in the suite.  When all tests have been processed, call [onDone].
  ///
  /// The [testCache] argument provides a persistent store that can be used to
  /// cache information about the test suite, so that directories do not need
  /// to be listed each time.
  Future forEachTest(
      TestCaseEvent onTest, Map<String, List<TestInformation>> testCache,
      [VoidFunction onDone]);

  /// This function will be called for every TestCase of this test suite.
  /// It will:
  ///  - handle sharding
  ///  - update SummaryReport
  ///  - handle SKIP/SKIP_BY_DESIGN markers
  ///  - test if the selector matches
  /// and will enqueue the test (if necessary).
  void enqueueNewTestCase(
      String testName, List<Command> commands, Set<Expectation> expectations,
      [TestInformation info]) {
    var displayName = '$suiteName/$testName';

    // If the test is not going to be run at all, then a RuntimeError,
    // MissingRuntimeError or Timeout will never occur.
    // Instead, treat that as Pass.
    if (configuration.runtime == Runtime.none) {
      expectations = expectations.toSet();
      expectations.remove(Expectation.runtimeError);
      expectations.remove(Expectation.ok);
      expectations.remove(Expectation.missingRuntimeError);
      expectations.remove(Expectation.timeout);
      if (expectations.isEmpty) expectations.add(Expectation.pass);
    }

    var negative = info != null ? isNegative(info) : false;
    var testCase = TestCase(displayName, commands, configuration, expectations,
        info: info);
    if (negative &&
        configuration.runtimeConfiguration.shouldSkipNegativeTests) {
      return;
    }

    // Handle sharding based on the original test path (i.e. all multitests
    // of a given original test belong to the same shard)
    if (configuration.shardCount > 1 &&
        testCase.hash % configuration.shardCount != configuration.shard - 1) {
      return;
    }

    // Test if the selector includes this test.
    var pattern = configuration.selectors[suiteName];
    if (!pattern.hasMatch(displayName)) {
      return;
    }
    if (configuration.testList != null &&
        !configuration.testList.contains(displayName)) {
      return;
    }

    if (configuration.hotReload || configuration.hotReloadRollback) {
      // Handle reload special cases.
      if (expectations.contains(Expectation.compileTimeError) ||
          testCase.hasCompileError) {
        // Running a test that expects a compilation error with hot reloading
        // is redundant with a regular run of the test.
        return;
      }
    }

    // Update Summary report
    if (configuration.printReport) {
      summaryReport.add(testCase);
    }

    // Handle skipped tests
    if (expectations.contains(Expectation.skip) ||
        expectations.contains(Expectation.skipByDesign) ||
        expectations.contains(Expectation.skipSlow)) {
      return;
    }

    if (configuration.fastTestsOnly &&
        (expectations.contains(Expectation.slow) ||
            expectations.contains(Expectation.skipSlow) ||
            expectations.contains(Expectation.timeout) ||
            expectations.contains(Expectation.dartkTimeout))) {
      return;
    }

    doTest(testCase);
  }

  bool isNegative(TestInformation info) =>
      info.hasCompileError ||
      info.hasRuntimeError && configuration.runtime != Runtime.none;

  String createGeneratedTestDirectoryHelper(
      String name, String dirname, Path testPath) {
    Path relative = testPath.relativeTo(Repository.dir);
    relative = relative.directoryPath.append(relative.filenameWithoutExtension);
    String testUniqueName = TestUtils.getShortName(relative.toString());

    Path generatedTestPath = Path(buildDir)
        .append('generated_$name')
        .append(dirname)
        .append(testUniqueName);

    TestUtils.mkdirRecursive(Path('.'), generatedTestPath);
    return File(generatedTestPath.toNativePath())
        .absolute
        .path
        .replaceAll('\\', '/');
  }

  String buildTestCaseDisplayName(Path suiteDir, Path originTestPath,
      {String multitestName = ""}) {
    Path testNamePath = originTestPath.relativeTo(suiteDir);
    var directory = testNamePath.directoryPath;
    var filenameWithoutExt = testNamePath.filenameWithoutExtension;

    String concat(String base, String part) {
      if (base == "") return part;
      if (part == "") return base;
      return "$base/$part";
    }

    var testName = "$directory";
    testName = concat(testName, "$filenameWithoutExt");
    testName = concat(testName, multitestName);
    return testName;
  }

  /// Create a directories for generated assets (tests, html files,
  /// pubspec checkouts ...).
  String createOutputDirectory(Path testPath) {
    var checked = configuration.isChecked ? '-checked' : '';
    var legacy = configuration.noPreviewDart2 ? '-legacy' : '';
    var minified = configuration.isMinified ? '-minified' : '';
    var sdk = configuration.useSdk ? '-sdk' : '';
    var dirName = "${configuration.compiler.name}-${configuration.runtime.name}"
        "$checked$legacy$minified$sdk";
    return createGeneratedTestDirectoryHelper("tests", dirName, testPath);
  }

  String createCompilationOutputDirectory(Path testPath) {
    var checked = configuration.isChecked ? '-checked' : '';
    var legacy = configuration.noPreviewDart2 ? '-legacy' : '';
    var minified = configuration.isMinified ? '-minified' : '';
    var csp = configuration.isCsp ? '-csp' : '';
    var sdk = configuration.useSdk ? '-sdk' : '';
    var dirName = "${configuration.compiler.name}"
        "$checked$legacy$minified$csp$sdk";
    return createGeneratedTestDirectoryHelper(
        "compilations", dirName, testPath);
  }

  String createPubspecCheckoutDirectory(Path directoryOfPubspecYaml) {
    var sdk = configuration.useSdk ? 'sdk' : '';
    return createGeneratedTestDirectoryHelper(
        "pubspec_checkouts", sdk, directoryOfPubspecYaml);
  }

  String createPubPackageBuildsDirectory(Path directoryOfPubspecYaml) {
    return createGeneratedTestDirectoryHelper(
        "pub_package_builds", 'public_packages', directoryOfPubspecYaml);
  }
}

/// A specialized [TestSuite] that runs tests written in C to unit test
/// the Dart virtual machine and its API.
///
/// The tests are compiled into a monolithic executable by the build step.
/// The executable lists its tests when run with the --list command line flag.
/// Individual tests are run by specifying them on the command line.
class VMTestSuite extends TestSuite {
  String targetRunnerPath;
  String hostRunnerPath;
  final String dartDir;

  VMTestSuite(TestConfiguration configuration)
      : dartDir = Repository.dir.toNativePath(),
        super(configuration, "vm", ["runtime/tests/vm/vm.status"]) {
    var binarySuffix = Platform.operatingSystem == 'windows' ? '.exe' : '';

    // For running the tests we use the given '$runnerName' binary
    targetRunnerPath = '$buildDir/run_vm_tests$binarySuffix';

    // For listing the tests we use the '$runnerName.host' binary if it exists
    // and use '$runnerName' if it doesn't.
    var hostBinary = '$targetRunnerPath.host$binarySuffix';
    if (File(hostBinary).existsSync()) {
      hostRunnerPath = hostBinary;
    } else {
      hostRunnerPath = targetRunnerPath;
    }
  }

  Future<Null> forEachTest(Function onTest, Map testCache,
      [VoidFunction onDone]) async {
    doTest = onTest;

    var statusFiles =
        statusFilePaths.map((statusFile) => "$dartDir/$statusFile").toList();
    var expectations = ExpectationSet.read(statusFiles, configuration);

    try {
      for (VMUnitTest test in await _listTests(hostRunnerPath)) {
        _addTest(expectations, test);
      }

      doTest = null;
      if (onDone != null) onDone();
    } catch (error, s) {
      print("Fatal error occured: $error");
      print(s);
      exit(1);
    }
  }

  void _addTest(ExpectationSet testExpectations, VMUnitTest test) {
    final fullName = 'cc/${test.name}';
    var expectations = testExpectations.expectations(fullName);

    // Get the expectation from the cc/ test itself.
    final Expectation testExpectation = Expectation.find(test.expectation);

    // Update the legacy status-file based expectations to include
    // [testExpectation].
    if (testExpectation != Expectation.pass) {
      expectations = Set<Expectation>.from(expectations)..add(testExpectation);
      expectations.removeWhere((e) => e == Expectation.pass);
    }

    // Update the new workflow based expectations to include [testExpectation].
    final Path filePath = null;
    final Path originTestPath = null;
    final hasSyntaxError = false;
    final hasStaticWarning = false;
    final hasCompileTimeError = testExpectation == Expectation.compileTimeError;
    final hasRuntimeError = testExpectation == Expectation.runtimeError;
    final hasCrash = testExpectation == Expectation.crash;
    final optionsFromFile = const <String, dynamic>{};
    final testInfo = TestInformation(filePath, originTestPath, optionsFromFile,
        hasSyntaxError, hasCompileTimeError, hasRuntimeError, hasStaticWarning,
        hasCrash: hasCrash);

    var args = configuration.standardOptions.toList();
    if (configuration.compilerConfiguration.previewDart2) {
      final filename = configuration.architecture == Architecture.x64
          ? '$buildDir/gen/kernel-service.dart.snapshot'
          : '$buildDir/gen/kernel_service.dill';
      final dfePath = Path(filename).absolute.toNativePath();
      // '--dfe' has to be the first argument for run_vm_test to pick it up.
      args.insert(0, '--dfe=$dfePath');
    }
    if (expectations.contains(Expectation.crash)) {
      args.insert(0, '--suppress-core-dump');
    }

    args.add(test.name);

    final command = Command.process(
        'run_vm_unittest', targetRunnerPath, args, environmentOverrides);
    enqueueNewTestCase(fullName, [command], expectations, testInfo);
  }

  Future<Iterable<VMUnitTest>> _listTests(String runnerPath) async {
    var result = await Process.run(runnerPath, ["--list"]);
    if (result.exitCode != 0) {
      throw "Failed to list tests: '$runnerPath --list'. "
          "Process exited with ${result.exitCode}";
    }

    return (result.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((name) => name.isNotEmpty)
        .map((String line) {
      final parts = line.split(' ');
      return VMUnitTest(parts[0].trim(), parts.skip(1).single);
    });
  }
}

class VMUnitTest {
  final String name;
  final String expectation;

  VMUnitTest(this.name, this.expectation);
}

class TestInformation {
  Path filePath;
  Path originTestPath;
  Map<String, dynamic> optionsFromFile;
  bool hasSyntaxError;
  bool hasCompileError;
  bool hasRuntimeError;
  bool hasStaticWarning;
  bool hasCrash;
  String multitestKey;

  TestInformation(
      this.filePath,
      this.originTestPath,
      this.optionsFromFile,
      this.hasSyntaxError,
      this.hasCompileError,
      this.hasRuntimeError,
      this.hasStaticWarning,
      {this.multitestKey = '',
      this.hasCrash = false}) {
    assert(filePath.isAbsolute);
  }
}

/// A standard [TestSuite] implementation that searches for tests in a
/// directory, and creates [TestCase]s that compile and/or run them.
class StandardTestSuite extends TestSuite {
  final Path suiteDir;
  ExpectationSet testExpectations;
  List<TestInformation> cachedTests;
  final Path dartDir;
  final bool listRecursively;
  final List<String> extraVmOptions;
  List<Uri> _dart2JsBootstrapDependencies;
  Set<String> _testListPossibleFilenames;
  RegExp _selectorFilenameRegExp;

  StandardTestSuite(TestConfiguration configuration, String suiteName,
      Path suiteDirectory, List<String> statusFilePaths,
      {bool recursive = false})
      : dartDir = Repository.dir,
        listRecursively = recursive,
        suiteDir = Repository.dir.join(suiteDirectory),
        extraVmOptions = configuration.vmOptions,
        super(configuration, suiteName, statusFilePaths) {
    // Initialize _dart2JsBootstrapDependencies.
    if (!configuration.useSdk) {
      _dart2JsBootstrapDependencies = [];
    } else {
      _dart2JsBootstrapDependencies = [
        Uri.base
            .resolveUri(Uri.directory(buildDir))
            .resolve('dart-sdk/bin/snapshots/dart2js.dart.snapshot')
      ];
    }

    // Initialize _testListPossibleFilenames.
    if (configuration.testList != null) {
      _testListPossibleFilenames = <String>{};
      for (String s in configuration.testList) {
        if (s.startsWith("$suiteName/")) {
          s = s.substring(s.indexOf('/') + 1);
          _testListPossibleFilenames
              .add(suiteDir.append('$s.dart').toNativePath());
          // If the test is a multitest, the filename doesn't include the label.
          // Also if it has multiple VMOptions.  If both, remove two labels.
          for (var i in [1, 2]) {
            // Twice
            if (s.lastIndexOf('/') != -1) {
              s = s.substring(0, s.lastIndexOf('/'));
              _testListPossibleFilenames
                  .add(suiteDir.append('$s.dart').toNativePath());
            }
          }
        }
      }
    }

    // Initialize _selectorFilenameRegExp.
    var pattern = configuration.selectors[suiteName].pattern;
    if (pattern.contains("/")) {
      var lastPart = pattern.substring(pattern.lastIndexOf("/") + 1);
      // If the selector is a multitest name ending in a number or 'none'
      // we also accept test file names that don't contain that last part.
      if (int.tryParse(lastPart) != null || lastPart == "none") {
        pattern = pattern.substring(0, pattern.lastIndexOf("/"));
      }
    }
    _selectorFilenameRegExp = RegExp(pattern);
  }

  /// Creates a test suite whose file organization matches an expected structure.
  /// To use this, your suite should look like:
  ///
  ///     dart/
  ///       path/
  ///         to/
  ///           mytestsuite/
  ///             mytestsuite.status
  ///             example1_test.dart
  ///             example2_test.dart
  ///             example3_test.dart
  ///
  /// The important parts:
  ///
  /// * The leaf directory name is the name of your test suite.
  /// * The status file uses the same name.
  /// * Test files are directly in that directory and end in "_test.dart".
  ///
  /// If you follow that convention, then you can construct one of these like:
  ///
  /// new StandardTestSuite.forDirectory(configuration, 'path/to/mytestsuite');
  ///
  /// instead of having to create a custom [StandardTestSuite] subclass. In
  /// particular, if you add 'path/to/mytestsuite' to [TEST_SUITE_DIRECTORIES]
  /// in test.dart, this will all be set up for you.
  factory StandardTestSuite.forDirectory(
      TestConfiguration configuration, Path directory) {
    var name = directory.filename;
    var status_paths = [
      '$directory/$name.status',
      '$directory/.status',
      '$directory/${name}_app_jit.status',
      '$directory/${name}_analyzer.status',
      '$directory/${name}_analyzer2.status',
      '$directory/${name}_dart2js.status',
      '$directory/${name}_dartdevc.status',
      '$directory/${name}_kernel.status',
      '$directory/${name}_precompiled.status',
      '$directory/${name}_spec_parser.status',
      '$directory/${name}_vm.status',
    ];

    return StandardTestSuite(configuration, name, directory, status_paths,
        recursive: true);
  }

  List<Uri> get dart2JsBootstrapDependencies => _dart2JsBootstrapDependencies;

  /// The default implementation assumes a file is a test if
  /// it ends in "_test.dart".
  bool isTestFile(String filename) => filename.endsWith("_test.dart");

  List<String> additionalOptions(Path filePath) => [];

  Future forEachTest(
      Function onTest, Map<String, List<TestInformation>> testCache,
      [VoidFunction onDone]) async {
    doTest = onTest;
    testExpectations = readExpectations();

    // Check if we have already found and generated the tests for this suite.
    if (!testCache.containsKey(suiteName)) {
      cachedTests = testCache[suiteName] = <TestInformation>[];
      await enqueueTests();
    } else {
      for (var info in testCache[suiteName]) {
        enqueueTestCaseFromTestInformation(info);
      }
    }
    testExpectations = null;
    cachedTests = null;
    doTest = null;
    if (onDone != null) onDone();
  }

  /// Reads the status files and completes with the parsed expectations.
  ExpectationSet readExpectations() {
    var statusFiles = statusFilePaths.where((String statusFilePath) {
      var file = File(dartDir.append(statusFilePath).toNativePath());
      return file.existsSync();
    }).map((statusFilePath) {
      return dartDir.append(statusFilePath).toNativePath();
    }).toList();

    return ExpectationSet.read(statusFiles, configuration);
  }

  Future enqueueTests() {
    Directory dir = Directory(suiteDir.toNativePath());
    return dir.exists().then((exists) {
      if (!exists) {
        print('Directory containing tests missing: ${suiteDir.toNativePath()}');
        return Future.value(null);
      } else {
        var group = FutureGroup();
        enqueueDirectory(dir, group);
        return group.future;
      }
    });
  }

  void enqueueDirectory(Directory dir, FutureGroup group) {
    var lister = dir
        .list(recursive: listRecursively)
        .where((fse) => fse is File)
        .forEach((FileSystemEntity entity) {
      enqueueFile((entity as File).path, group);
    });
    group.add(lister);
  }

  void enqueueFile(String filename, FutureGroup group) {
    // This is an optimization to avoid scanning and generating extra tests.
    // The definitive check against configuration.testList is performed in
    // TestSuite.enqueueNewTestCase().
    if (_testListPossibleFilenames?.contains(filename) == false) return;
    // Note: have to use Path instead of a filename for matching because
    // on Windows we need to convert backward slashes to forward slashes.
    // Our display test names (and filters) are given using forward slashes
    // while filenames on Windows use backwards slashes.
    final Path filePath = Path(filename);
    if (!_selectorFilenameRegExp.hasMatch(filePath.toString())) return;

    if (!isTestFile(filename)) return;

    var optionsFromFile = readOptionsFromFile(Uri.file(filename));
    CreateTest createTestCase = makeTestCaseCreator(optionsFromFile);

    if (optionsFromFile['isMultitest'] as bool) {
      group.add(doMultitest(filePath, buildDir, suiteDir, createTestCase,
          configuration.hotReload || configuration.hotReloadRollback));
    } else {
      createTestCase(filePath, filePath,
          hasSyntaxError: optionsFromFile['hasSyntaxError'] as bool,
          hasCompileError: optionsFromFile['hasCompileError'] as bool,
          hasRuntimeError: optionsFromFile['hasRuntimeError'] as bool,
          hasStaticWarning: optionsFromFile['hasStaticWarning'] as bool);
    }
  }

  void enqueueTestCaseFromTestInformation(TestInformation info) {
    String testName = buildTestCaseDisplayName(suiteDir, info.originTestPath,
        multitestName: info.optionsFromFile['isMultitest'] as bool
            ? info.multitestKey
            : "");
    var optionsFromFile = info.optionsFromFile;

    // If this test is inside a package, we will check if there is a
    // pubspec.yaml file and if so, create a custom package root for it.
    Path packageRoot;
    Path packages;

    if (optionsFromFile['packageRoot'] == null &&
        optionsFromFile['packages'] == null) {
      if (configuration.packageRoot != null) {
        packageRoot = Path(configuration.packageRoot);
        optionsFromFile['packageRoot'] = packageRoot.toNativePath();
      }
      if (configuration.packages != null) {
        Path packages = Path(configuration.packages);
        optionsFromFile['packages'] = packages.toNativePath();
      }
    }
    if (configuration.compilerConfiguration.hasCompiler &&
        info.hasCompileError) {
      // If a compile-time error is expected, and we're testing a
      // compiler, we never need to attempt to run the program (in a
      // browser or otherwise).
      enqueueStandardTest(info, testName);
    } else if (configuration.runtime.isBrowser) {
      var expectationsMap = <String, Set<Expectation>>{};

      if (info.optionsFromFile['isMultiHtmlTest'] as bool) {
        // A browser multi-test has multiple expectations for one test file.
        // Find all the different sub-test expectations for one entire test
        // file.
        var subtestNames = info.optionsFromFile['subtestNames'] as List<String>;
        expectationsMap = <String, Set<Expectation>>{};
        for (var subtest in subtestNames) {
          expectationsMap[subtest] =
              testExpectations.expectations('$testName/$subtest');
        }
      } else {
        expectationsMap[testName] = testExpectations.expectations(testName);
      }

      _enqueueBrowserTest(
          packageRoot, packages, info, testName, expectationsMap);
    } else {
      enqueueStandardTest(info, testName);
    }
  }

  void enqueueStandardTest(TestInformation info, String testName) {
    var commonArguments =
        commonArgumentsFromFile(info.filePath, info.optionsFromFile);

    var vmOptionsList = getVmOptions(info.optionsFromFile);
    assert(!vmOptionsList.isEmpty);

    for (var vmOptionsVariant = 0;
        vmOptionsVariant < vmOptionsList.length;
        vmOptionsVariant++) {
      var vmOptions = vmOptionsList[vmOptionsVariant];
      var allVmOptions = vmOptions;
      if (!extraVmOptions.isEmpty) {
        allVmOptions = vmOptions.toList()..addAll(extraVmOptions);
      }

      var expectations = testExpectations.expectations(testName);
      var isCrashExpected = expectations.contains(Expectation.crash);
      var commands = makeCommands(info, vmOptionsVariant, allVmOptions,
          commonArguments, isCrashExpected);
      var variantTestName = testName;
      if (vmOptionsList.length > 1) {
        variantTestName = "$testName/$vmOptionsVariant";
      }
      enqueueNewTestCase(variantTestName, commands, expectations, info);
    }
  }

  List<Command> makeCommands(TestInformation info, int vmOptionsVariant,
      List<String> vmOptions, List<String> args, bool isCrashExpected) {
    var commands = <Command>[];
    var compilerConfiguration = configuration.compilerConfiguration;
    var sharedOptions = info.optionsFromFile['sharedOptions'] as List<String>;
    var dartOptions = info.optionsFromFile['dartOptions'] as List<String>;
    var dart2jsOptions = info.optionsFromFile['dart2jsOptions'] as List<String>;
    var ddcOptions = info.optionsFromFile['ddcOptions'] as List<String>;

    var isMultitest = info.optionsFromFile["isMultitest"] as bool;
    assert(!isMultitest || dartOptions.isEmpty);

    var compileTimeArguments = <String>[];
    String tempDir;
    if (compilerConfiguration.hasCompiler) {
      compileTimeArguments = compilerConfiguration.computeCompilerArguments(
          vmOptions,
          sharedOptions,
          dartOptions,
          dart2jsOptions,
          ddcOptions,
          args);
      // Avoid doing this for analyzer.
      var path = info.filePath;
      if (vmOptionsVariant != 0) {
        // Ensure a unique directory for each test case.
        path = path.join(Path(vmOptionsVariant.toString()));
      }
      tempDir = createCompilationOutputDirectory(path);

      var otherResources =
          info.optionsFromFile['otherResources'] as List<String>;
      for (var name in otherResources) {
        var namePath = Path(name);
        var fromPath = info.filePath.directoryPath.join(namePath);
        File('$tempDir/$name').parent.createSync(recursive: true);
        File(fromPath.toNativePath()).copySync('$tempDir/$name');
      }
    }

    var compilationArtifact = compilerConfiguration.computeCompilationArtifact(
        tempDir, compileTimeArguments, environmentOverrides);
    if (!configuration.skipCompilation) {
      commands.addAll(compilationArtifact.commands);
    }

    if (info.hasCompileError &&
        compilerConfiguration.hasCompiler &&
        !compilerConfiguration.runRuntimeDespiteMissingCompileTimeError) {
      // Do not attempt to run the compiled result. A compilation
      // error should be reported by the compilation command.
      return commands;
    }

    vmOptions = vmOptions
        .map((s) =>
            s.replaceAll("__RANDOM__", "${Random().nextInt(0x7fffffff)}"))
        .toList();

    var runtimeArguments = compilerConfiguration.computeRuntimeArguments(
        configuration.runtimeConfiguration,
        info,
        vmOptions,
        sharedOptions,
        dartOptions,
        args,
        compilationArtifact);

    var environment = environmentOverrides;
    var extraEnv = info.optionsFromFile['environment'] as Map<String, String>;
    if (extraEnv != null) {
      environment = {...environment, ...extraEnv};
    }

    return commands
      ..addAll(configuration.runtimeConfiguration.computeRuntimeCommands(
          compilationArtifact,
          runtimeArguments,
          environment,
          info.optionsFromFile["sharedObjects"] as List<String>,
          isCrashExpected));
  }

  CreateTest makeTestCaseCreator(Map<String, dynamic> optionsFromFile) {
    return (Path filePath, Path originTestPath,
        {bool hasSyntaxError,
        bool hasCompileError,
        bool hasRuntimeError,
        bool hasStaticWarning = false,
        String multitestKey}) {
      // Cache the test information for each test case.
      var info = TestInformation(filePath, originTestPath, optionsFromFile,
          hasSyntaxError, hasCompileError, hasRuntimeError, hasStaticWarning,
          multitestKey: multitestKey);
      cachedTests.add(info);
      enqueueTestCaseFromTestInformation(info);
    };
  }

  /// Takes a [file], which is either located in the dart or in the build
  /// directory, and returns a String representing the relative path to either
  /// the dart or the build directory.
  ///
  /// Thus, the returned [String] will be the path component of the URL
  /// corresponding to [file] (the HTTP server serves files relative to the
  /// dart/build directories).
  String _createUrlPathFromFile(Path file) {
    file = file.absolute;

    var relativeBuildDir = Path(configuration.buildDirectory);
    var buildDir = relativeBuildDir.absolute;
    var dartDir = Repository.dir.absolute;

    var fileString = file.toString();
    if (fileString.startsWith(buildDir.toString())) {
      var fileRelativeToBuildDir = file.relativeTo(buildDir);
      return "/$prefixBuildDir/$fileRelativeToBuildDir";
    } else if (fileString.startsWith(dartDir.toString())) {
      var fileRelativeToDartDir = file.relativeTo(dartDir);
      return "/$prefixDartDir/$fileRelativeToDartDir";
    }

    // Unreachable.
    print("Cannot create URL for path $file. Not in build or dart directory.");
    exit(1);
    return null;
  }

  String _uriForBrowserTest(String pathComponent, [String subtestName]) {
    // Note: If we run test.py with the "--list" option, no http servers
    // will be started. So we return a dummy url instead.
    if (configuration.listTests) {
      return Uri.parse('http://listing_the_tests_only').toString();
    }

    var serverPort = configuration.servers.port;
    var crossOriginPort = configuration.servers.crossOriginPort;
    var parameters = {'crossOriginPort': crossOriginPort.toString()};
    if (subtestName != null) {
      parameters['group'] = subtestName;
    }
    return Uri(
            scheme: 'http',
            host: configuration.localIP,
            port: serverPort,
            path: pathComponent,
            queryParameters: parameters)
        .toString();
  }

  /// Enqueues a test that runs in a browser.
  ///
  /// Creates a [Command] that compiles the test to JavaScript and writes that
  /// in a generated output directory. Any additional framework and HTML files
  /// are put there too. Then adds another [Command] the spawn the browser and
  /// run the test.
  ///
  /// In order to handle browser multitests, [expectations] is a map of subtest
  /// names to expectation sets. If the test is not a multitest, the map has
  /// a single key, [testName].
  void _enqueueBrowserTest(
      Path packageRoot,
      Path packages,
      TestInformation info,
      String testName,
      Map<String, Set<Expectation>> expectations) {
    var tempDir = createOutputDirectory(info.filePath);
    var fileName = info.filePath.toNativePath();
    var optionsFromFile = info.optionsFromFile;
    var compilationTempDir = createCompilationOutputDirectory(info.filePath);
    var nameNoExt = info.filePath.filenameWithoutExtension;
    var outputDir = compilationTempDir;
    var commonArguments =
        commonArgumentsFromFile(info.filePath, optionsFromFile);

    // Use existing HTML document if available.
    String content;
    var customHtml = File(
        info.filePath.directoryPath.append('$nameNoExt.html').toNativePath());
    if (customHtml.existsSync()) {
      outputDir = tempDir;
      content = customHtml.readAsStringSync().replaceAll(
          '%TEST_SCRIPTS%', '<script src="$nameNoExt.js"></script>');
    } else {
      // Synthesize an HTML file for the test.
      if (configuration.compiler == Compiler.dart2js) {
        var scriptPath =
            _createUrlPathFromFile(Path('$compilationTempDir/$nameNoExt.js'));
        content = dart2jsHtml(fileName, scriptPath);
      } else {
        var jsDir =
            Path(compilationTempDir).relativeTo(Repository.dir).toString();
        content = dartdevcHtml(nameNoExt, jsDir, configuration.compiler);
      }
    }

    var htmlPath = '$tempDir/test.html';
    File(htmlPath).writeAsStringSync(content);

    // Construct the command(s) that compile all the inputs needed by the
    // browser test.
    var commands = <Command>[];
    const supportedCompilers = {
      Compiler.dart2js,
      Compiler.dartdevc,
      Compiler.dartdevk
    };
    assert(supportedCompilers.contains(configuration.compiler));
    var sharedOptions = optionsFromFile["sharedOptions"] as List<String>;
    var dart2jsOptions = optionsFromFile["dart2jsOptions"] as List<String>;
    var ddcOptions = optionsFromFile["ddcOptions"] as List<String>;

    var args = configuration.compilerConfiguration.computeCompilerArguments(
        null, sharedOptions, null, dart2jsOptions, ddcOptions, commonArguments);
    var compilation = configuration.compilerConfiguration
        .computeCompilationArtifact(outputDir, args, environmentOverrides);
    commands.addAll(compilation.commands);

    if (info.optionsFromFile['isMultiHtmlTest'] as bool) {
      // Variables for browser multi-tests.
      var subtestNames = info.optionsFromFile['subtestNames'] as List<String>;
      for (var subtestName in subtestNames) {
        _enqueueSingleBrowserTest(commands, info, '$testName/$subtestName',
            subtestName, expectations[subtestName], htmlPath);
      }
    } else {
      _enqueueSingleBrowserTest(
          commands, info, testName, null, expectations[testName], htmlPath);
    }
  }

  /// Enqueues a single browser test, or a single subtest of an HTML multitest.
  void _enqueueSingleBrowserTest(
      List<Command> commands,
      TestInformation info,
      String testName,
      String subtestName,
      Set<Expectation> expectations,
      String htmlPath) {
    // Construct the command that executes the browser test.
    commands = commands.toList();

    var htmlPathSubtest = _createUrlPathFromFile(Path(htmlPath));
    var fullHtmlPath = _uriForBrowserTest(htmlPathSubtest, subtestName);

    commands.add(Command.browserTest(fullHtmlPath, configuration,
        retry: !isNegative(info)));

    var fullName = testName;
    if (subtestName != null) fullName += "/$subtestName";
    enqueueNewTestCase(fullName, commands, expectations, info);
  }

  List<String> commonArgumentsFromFile(
      Path filePath, Map<String, dynamic> optionsFromFile) {
    var args = configuration.standardOptions.toList();

    var packages = packagesArgument(optionsFromFile['packageRoot'] as String,
        optionsFromFile['packages'] as String);
    if (packages != null) {
      args.add(packages);
    }
    args.addAll(additionalOptions(filePath));
    if (configuration.compiler == Compiler.dart2analyzer) {
      args.add('--format=machine');
      args.add('--no-hints');

      if (filePath.filename.contains("dart2js") ||
          filePath.directoryPath.segments().last.contains('html_common')) {
        args.add("--use-dart2js-libraries");
      }
    }

    args.add(filePath.toNativePath());

    return args;
  }

  String packagesArgument(String packageRootFromFile, String packagesFromFile) {
    if (packageRootFromFile == 'none' || packagesFromFile == 'none') {
      return null;
    } else if (packagesFromFile != null) {
      return '--packages=$packagesFromFile';
    } else if (packageRootFromFile != null) {
      return '--package-root=$packageRootFromFile';
    } else {
      return null;
    }
  }

  /// Special options for individual tests are currently specified in various
  /// ways: with comments directly in test files, by using certain imports, or
  /// by creating additional files in the test directories.
  ///
  /// Here is a list of options that are used by 'test.dart' today:
  ///   - Flags can be passed to the vm process that runs the test by adding a
  ///   comment to the test file:
  ///
  ///     // VMOptions=--flag1 --flag2
  ///
  ///   - Flags can be passed to dart2js, vm or dartdevc by adding a comment to
  ///   the test file:
  ///
  ///     // SharedOptions=--flag1 --flag2
  ///
  ///   - Flags can be passed to dart2js by adding a comment to the test file:
  ///
  ///     // dart2jsOptions=--flag1 --flag2
  ///
  ///   - Flags can be passed to the dart script that contains the test also
  ///   using comments, as follows:
  ///
  ///     // DartOptions=--flag1 --flag2
  ///
  ///   - Extra environment variables can be passed to the process that runs
  ///   the test by adding comment(s) to the test file:
  ///
  ///     // Environment=ENV_VAR1=foo bar
  ///     // Environment=ENV_VAR2=bazz
  ///
  ///   - Most tests are not web tests, but can (and will be) wrapped within
  ///   an HTML file and another script file to test them also on browser
  ///   environments (e.g. language and corelib tests are run this way).
  ///   We deduce that if a file with the same name as the test, but ending in
  ///   .html instead of .dart exists, the test was intended to be a web test
  ///   and no wrapping is necessary.
  ///
  ///     // SharedObjects=foobar
  ///
  ///   - This test requires libfoobar.so, libfoobar.dylib or foobar.dll to be
  ///   in the system linker path of the VM.
  ///
  ///   - 'test.dart' assumes tests fail if
  ///   the process returns a non-zero exit code (in the case of web tests, we
  ///   check for PASS/FAIL indications in the test output).
  ///
  /// This method is static as the map is cached and shared amongst
  /// configurations, so it may not use [configuration].
  Map<String, dynamic> readOptionsFromFile(Uri uri) {
    if (uri.path.endsWith('.dill')) {
      return optionsFromKernelFile();
    }
    var testOptionsRegExp = RegExp(r"// VMOptions=(.*)");
    var environmentRegExp = RegExp(r"// Environment=(.*)");
    var otherResourcesRegExp = RegExp(r"// OtherResources=(.*)");
    var sharedObjectsRegExp = RegExp(r"// SharedObjects=(.*)");
    var packageRootRegExp = RegExp(r"// PackageRoot=(.*)");
    var packagesRegExp = RegExp(r"// Packages=(.*)");
    var isolateStubsRegExp = RegExp(r"// IsolateStubs=(.*)");
    // TODO(gram) Clean these up once the old directives are not supported.
    var domImportRegExp = RegExp(
        r"^[#]?import.*dart:(html|web_audio|indexed_db|svg|web_sql)",
        multiLine: true);

    var bytes = File.fromUri(uri).readAsBytesSync();
    var contents = decodeUtf8(bytes);
    bytes = null;

    // Find the options in the file.
    var result = <List<String>>[];
    List<String> dartOptions;
    List<String> sharedOptions;
    List<String> dart2jsOptions;
    List<String> ddcOptions;
    Map<String, String> environment;
    String packageRoot;
    String packages;

    List<String> wordSplit(String s) =>
        s.split(' ').where((e) => e != '').toList();

    List<String> singleListOfOptions(String name) {
      var matches = RegExp('// $name=(.*)').allMatches(contents);
      List<String> options;
      for (var match in matches) {
        if (options != null) {
          throw Exception(
              'More than one "// $name=" line in test ${uri.toFilePath()}');
        }
        options = wordSplit(match[1]);
      }
      return options;
    }

    var matches = testOptionsRegExp.allMatches(contents);
    for (var match in matches) {
      result.add(wordSplit(match[1]));
    }
    if (result.isEmpty) result.add(<String>[]);

    dartOptions = singleListOfOptions('DartOptions');
    sharedOptions = singleListOfOptions('SharedOptions');
    dart2jsOptions = singleListOfOptions('dart2jsOptions');
    ddcOptions = singleListOfOptions('dartdevcOptions');

    matches = environmentRegExp.allMatches(contents);
    for (var match in matches) {
      var envDef = match[1];
      var pos = envDef.indexOf('=');
      var name = (pos < 0) ? envDef : envDef.substring(0, pos);
      var value = (pos < 0) ? '' : envDef.substring(pos + 1);
      environment ??= <String, String>{};
      environment[name] = value;
    }

    matches = packageRootRegExp.allMatches(contents);
    for (var match in matches) {
      if (packageRoot != null || packages != null) {
        throw Exception(
            'More than one "// Package... line in test ${uri.toFilePath()}');
      }
      packageRoot = match[1];
      if (packageRoot != 'none') {
        // PackageRoot=none means that no packages or package-root option
        // should be given. Any other value overrides package-root and
        // removes any packages option.  Don't use with // Packages=.
        packageRoot = uri.resolveUri(Uri.directory(packageRoot)).toFilePath();
      }
    }

    matches = packagesRegExp.allMatches(contents);
    for (var match in matches) {
      if (packages != null || packageRoot != null) {
        throw Exception(
            'More than one "// Package..." line in test ${uri.toFilePath()}');
      }
      packages = match[1];
      if (packages != 'none') {
        // Packages=none means that no packages or package-root option
        // should be given. Any other value overrides packages and removes
        // any package-root option. Don't use with // PackageRoot=.
        packages = uri.resolveUri(Uri.file(packages)).toFilePath();
      }
    }

    var otherResources = <String>[];
    matches = otherResourcesRegExp.allMatches(contents);
    for (var match in matches) {
      otherResources.addAll(wordSplit(match[1]));
    }

    var sharedObjects = <String>[];
    matches = sharedObjectsRegExp.allMatches(contents);
    for (var match in matches) {
      sharedObjects.addAll(wordSplit(match[1]));
    }

    var isMultitest = _multiTestRegExp.hasMatch(contents);
    var isMultiHtmlTest = _multiHtmlTestRegExp.hasMatch(contents);
    var isolateMatch = isolateStubsRegExp.firstMatch(contents);
    var isolateStubs = isolateMatch != null ? isolateMatch[1] : '';
    var containsDomImport = domImportRegExp.hasMatch(contents);

    var subtestNames = <String>[];
    var matchesIter = _multiHtmlTestGroupRegExp.allMatches(contents).iterator;
    while (matchesIter.moveNext() && isMultiHtmlTest) {
      var fullMatch = matchesIter.current.group(0);
      subtestNames.add(fullMatch.substring(fullMatch.indexOf("'") + 1));
    }

    // TODO(rnystrom): During the migration of the existing tests to Dart 2.0,
    // we have a number of tests that used to both generate static type warnings
    // and also validate some runtime behavior in an implementation that
    // ignores those warnings. Those warnings are now errors. The test code
    // validates the runtime behavior can and should be removed, but the code
    // that causes the static warning should still be preserved since that is
    // part of our coverage of the static type system.
    //
    // The test needs to indicate that it should have a static error. We could
    // put that in the status file, but that makes it confusing because it
    // would look like implementations that *don't* report the error are more
    // correct. Eventually, we want to have a notation similar to what front_end
    // is using for the inference tests where we can put a comment inside the
    // test that says "This specific static error should be reported right by
    // this token."
    //
    // That system isn't in place yet, so we do a crude approximation here in
    // test.dart. If a test contains `/*@compile-error=`, which matches the
    // beginning of the tag syntax that front_end uses, then we assume that
    // this test must have a static error somewhere in it.
    //
    // Redo this code once we have a more precise test framework for detecting
    // and locating these errors.
    final hasSyntaxError = contents.contains("@syntax-error");
    final hasCompileError =
        hasSyntaxError || contents.contains("@compile-error");
    final hasRuntimeError = contents.contains("@runtime-error");
    final hasStaticWarning = contents.contains("@static-warning");

    return {
      "vmOptions": result,
      "sharedOptions": sharedOptions ?? <String>[],
      "dart2jsOptions": dart2jsOptions ?? <String>[],
      "ddcOptions": ddcOptions ?? <String>[],
      "dartOptions": dartOptions ?? <String>[],
      "environment": environment,
      "packageRoot": packageRoot,
      "packages": packages,
      "hasSyntaxError": hasSyntaxError,
      "hasCompileError": hasCompileError,
      "hasRuntimeError": hasRuntimeError,
      "hasStaticWarning": hasStaticWarning,
      "otherResources": otherResources,
      "sharedObjects": sharedObjects,
      "isMultitest": isMultitest,
      "isMultiHtmlTest": isMultiHtmlTest,
      "subtestNames": subtestNames,
      "isolateStubs": isolateStubs,
      "containsDomImport": containsDomImport
    };
  }

  Map<String, dynamic> optionsFromKernelFile() {
    return const {
      "vmOptions": [<String>[]],
      "sharedOptions": <String>[],
      "dart2jsOptions": <String>[],
      "dartOptions": <String>[],
      "packageRoot": null,
      "packages": null,
      "hasSyntaxError": false,
      "hasCompileError": false,
      "hasRuntimeError": false,
      "hasStaticWarning": false,
      "isMultitest": false,
      "isMultiHtmlTest": false,
      "subtestNames": [],
      "isolateStubs": '',
      "containsDomImport": false,
    };
  }

  List<List<String>> getVmOptions(Map<String, dynamic> optionsFromFile) {
    const compilers = [
      Compiler.none,
      Compiler.dartk,
      Compiler.dartkb,
      Compiler.dartkp,
      Compiler.precompiler,
      Compiler.appJit,
      Compiler.appJitk,
    ];

    const runtimes = [Runtime.none, Runtime.dartPrecompiled, Runtime.vm];

    var needsVmOptions = compilers.contains(configuration.compiler) &&
        runtimes.contains(configuration.runtime);
    if (!needsVmOptions) return [[]];
    return optionsFromFile['vmOptions'] as List<List<String>>;
  }
}

/// Used for testing packages in one-off settings, i.e., we pass in the actual
/// directory that we want to test.
class PKGTestSuite extends StandardTestSuite {
  PKGTestSuite(TestConfiguration configuration, Path directoryPath)
      : super(configuration, directoryPath.filename, directoryPath,
            ["$directoryPath/.status"],
            recursive: true);

  void _enqueueBrowserTest(Path packageRoot, packages, TestInformation info,
      String testName, Map<String, Set<Expectation>> expectations) {
    var filePath = info.filePath;
    var dir = filePath.directoryPath;
    var nameNoExt = filePath.filenameWithoutExtension;
    var customHtmlPath = dir.append('$nameNoExt.html');
    var customHtml = File(customHtmlPath.toNativePath());
    if (!customHtml.existsSync()) {
      super._enqueueBrowserTest(
          packageRoot, packages, info, testName, expectations);
    } else {
      var fullPath = _createUrlPathFromFile(customHtmlPath);
      var command = Command.browserTest(fullPath, configuration,
          retry: !isNegative(info));
      enqueueNewTestCase(testName, [command], expectations[testName], info);
    }
  }
}

class AnalyzeLibraryTestSuite extends StandardTestSuite {
  static Path _libraryPath(TestConfiguration configuration) =>
      Path(configuration.useSdk
          ? '${configuration.buildDirectory}/dart-sdk'
          : 'sdk');

  bool get listRecursively => true;

  AnalyzeLibraryTestSuite(TestConfiguration configuration)
      : super(configuration, 'analyze_library', _libraryPath(configuration),
            ['tests/lib_2/analyzer/analyze_library.status']);

  List<String> additionalOptions(Path filePath, {bool showSdkWarnings}) =>
      const ['--fatal-warnings', '--fatal-type-errors', '--sdk-warnings'];

  Future enqueueTests() {
    var group = FutureGroup();

    var dir = Directory(suiteDir.append('lib').toNativePath());
    if (dir.existsSync()) {
      enqueueDirectory(dir, group);
    }

    return group.future;
  }

  bool isTestFile(String filename) {
    // NOTE: We exclude tests and patch files for now.
    return filename.endsWith(".dart") &&
        !filename.endsWith("_test.dart") &&
        !filename.contains("_internal/js_runtime/lib");
  }
}
