// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:test/src/backend/declarer.dart';
import 'package:test/src/backend/group.dart';
import 'package:test/src/backend/group_entry.dart';
import 'package:test/src/backend/invoker.dart';
import 'package:test/src/backend/live_test.dart';
import 'package:test/src/backend/metadata.dart';
import 'package:test/src/backend/runtime.dart';
import 'package:test/src/backend/state.dart';
import 'package:test/src/backend/suite.dart';
import 'package:test/src/backend/suite_platform.dart';
import 'package:test/src/runner/application_exception.dart';
import 'package:test/src/runner/configuration/suite.dart';
import 'package:test/src/runner/engine.dart';
import 'package:test/src/runner/load_exception.dart';
import 'package:test/src/runner/plugin/environment.dart';
import 'package:test/src/runner/runner_suite.dart';
import 'package:test/src/util/remote_exception.dart';
import 'package:test/test.dart';

/// The string representation of an untyped closure with no arguments.
///
/// This differs between dart2js and the VM.
final String closureString = (() {}).toString();

/// A dummy suite platform to use for testing suites.
final suitePlatform = SuitePlatform(Runtime.vm);

// The last state change detected via [expectStates].
State lastState;

/// Asserts that exactly [states] will be emitted via [liveTest.onStateChange].
///
/// The most recent emitted state is stored in [_lastState].
void expectStates(LiveTest liveTest, Iterable<State> statesIter) {
  var states = Queue.from(statesIter);
  liveTest.onStateChange.listen(expectAsync1((state) {
    lastState = state;
    expect(state, equals(states.removeFirst()));
  }, count: states.length, max: states.length));
}

/// Asserts that errors will be emitted via [liveTest.onError] that match
/// [validators], in order.
void expectErrors(LiveTest liveTest, Iterable<Function> validatorsIter) {
  var validators = Queue.from(validatorsIter);
  liveTest.onError.listen(expectAsync1((error) {
    validators.removeFirst()(error.error);
  }, count: validators.length, max: validators.length));
}

/// Asserts that [liveTest] will have a single failure with message `"oh no"`.
void expectSingleFailure(LiveTest liveTest) {
  expectStates(liveTest, [
    const State(Status.running, Result.success),
    const State(Status.complete, Result.failure)
  ]);

  expectErrors(liveTest, [
    (error) {
      expect(lastState.status, equals(Status.complete));
      expect(error, isTestFailure("oh no"));
    }
  ]);
}

/// Asserts that [liveTest] will have a single error, the string `"oh no"`.
void expectSingleError(LiveTest liveTest) {
  expectStates(liveTest, [
    const State(Status.running, Result.success),
    const State(Status.complete, Result.error)
  ]);

  expectErrors(liveTest, [
    (error) {
      expect(lastState.status, equals(Status.complete));
      expect(error, equals("oh no"));
    }
  ]);
}

/// Returns a matcher that matches a callback or Future that throws a
/// [TestFailure] with the given [message].
///
/// [message] can be a string or a [Matcher].
Matcher throwsTestFailure(message) => throwsA(isTestFailure(message));

/// Returns a matcher that matches a [TestFailure] with the given [message].
///
/// [message] can be a string or a [Matcher].
Matcher isTestFailure(message) => _IsTestFailure(wrapMatcher(message));

class _IsTestFailure extends Matcher {
  final Matcher _message;

  _IsTestFailure(this._message);

  bool matches(item, Map matchState) =>
      item is TestFailure && _message.matches(item.message, matchState);

  Description describe(Description description) =>
      description.add('a TestFailure with message ').addDescriptionOf(_message);

  Description describeMismatch(
      item, Description mismatchDescription, Map matchState, bool verbose) {
    if (item is! TestFailure) {
      return mismatchDescription
          .addDescriptionOf(item)
          .add('is not a TestFailure');
    } else {
      return mismatchDescription
          .add('message ')
          .addDescriptionOf(item.message)
          .add(' is not ')
          .addDescriptionOf(_message);
    }
  }
}

/// Returns a matcher that matches a [RemoteException] with the given [message].
///
/// [message] can be a string or a [Matcher].
Matcher isRemoteException(message) => _IsRemoteException(wrapMatcher(message));

class _IsRemoteException extends Matcher {
  final Matcher _message;

  _IsRemoteException(this._message);

  bool matches(item, Map matchState) =>
      item is RemoteException && _message.matches(item.message, matchState);

  Description describe(Description description) => description
      .add('a RemoteException with message ')
      .addDescriptionOf(_message);

  Description describeMismatch(
      item, Description mismatchDescription, Map matchState, bool verbose) {
    if (item is! RemoteException) {
      return mismatchDescription
          .addDescriptionOf(item)
          .add('is not a RemoteException');
    } else {
      return mismatchDescription
          .add('message ')
          .addDescriptionOf(item)
          .add(' is not ')
          .addDescriptionOf(_message);
    }
  }
}

/// Returns a matcher that matches a [LoadException] with the given
/// [innerError].
///
/// [innerError] can be a string or a [Matcher].
Matcher isLoadException(innerError) =>
    _IsLoadException(wrapMatcher(innerError));

class _IsLoadException extends Matcher {
  final Matcher _innerError;

  _IsLoadException(this._innerError);

  bool matches(item, Map matchState) =>
      item is LoadException && _innerError.matches(item.innerError, matchState);

  Description describe(Description description) => description
      .add('a LoadException with message ')
      .addDescriptionOf(_innerError);

  Description describeMismatch(
      item, Description mismatchDescription, Map matchState, bool verbose) {
    if (item is! LoadException) {
      return mismatchDescription
          .addDescriptionOf(item)
          .add('is not a LoadException');
    } else {
      return mismatchDescription
          .add('inner error ')
          .addDescriptionOf(item)
          .add(' is not ')
          .addDescriptionOf(_innerError);
    }
  }
}

/// Returns a matcher that matches a [ApplicationException] with the given
/// [message].
///
/// [message] can be a string or a [Matcher].
Matcher isApplicationException(message) =>
    _IsApplicationException(wrapMatcher(message));

class _IsApplicationException extends Matcher {
  final Matcher _message;

  _IsApplicationException(this._message);

  bool matches(item, Map matchState) =>
      item is ApplicationException &&
      _message.matches(item.message, matchState);

  Description describe(Description description) => description
      .add('a ApplicationException with message ')
      .addDescriptionOf(_message);

  Description describeMismatch(
      item, Description mismatchDescription, Map matchState, bool verbose) {
    if (item is! ApplicationException) {
      return mismatchDescription
          .addDescriptionOf(item)
          .add('is not a ApplicationException');
    } else {
      return mismatchDescription
          .add('message ')
          .addDescriptionOf(item)
          .add(' is not ')
          .addDescriptionOf(_message);
    }
  }
}

/// Returns a local [LiveTest] that runs [body].
LiveTest createTest(body()) {
  var test = LocalTest("test", Metadata(), body);
  var suite = Suite(Group.root([test]), suitePlatform);
  return test.load(suite);
}

/// Runs [body] as a test.
///
/// Once it completes, returns the [LiveTest] used to run it.
Future<LiveTest> runTestBody(body()) async {
  var liveTest = createTest(body);
  await liveTest.run();
  return liveTest;
}

/// Asserts that [liveTest] has completed and passed.
///
/// If the test had any errors, they're surfaced nicely into the outer test.
void expectTestPassed(LiveTest liveTest) {
  // Since the test is expected to pass, we forward any current or future errors
  // to the outer test, because they're definitely unexpected.
  for (var error in liveTest.errors) {
    registerException(error.error, error.stackTrace);
  }
  liveTest.onError.listen((error) {
    registerException(error.error, error.stackTrace);
  });

  expect(liveTest.state.status, equals(Status.complete));
  expect(liveTest.state.result, equals(Result.success));
}

/// Asserts that [liveTest] failed with a single [TestFailure] whose message
/// matches [message].
void expectTestFailed(LiveTest liveTest, message) {
  expect(liveTest.state.status, equals(Status.complete));
  expect(liveTest.state.result, equals(Result.failure));
  expect(liveTest.errors, hasLength(1));
  expect(liveTest.errors.first.error, isTestFailure(message));
}

/// Assert that the [test] callback causes a test to block until [stopBlocking]
/// is called at some later time.
///
/// [stopBlocking] is passed the return value of [test].
Future expectTestBlocks(test(), stopBlocking(value)) async {
  LiveTest liveTest;
  Future future;
  liveTest = createTest(() {
    var value = test();
    future = pumpEventQueue().then((_) {
      expect(liveTest.state.status, equals(Status.running));
      stopBlocking(value);
    });
  });

  await liveTest.run();
  expectTestPassed(liveTest);
  // Ensure that the outer test doesn't complete until the inner future
  // completes.
  return future;
}

/// Runs [body] with a declarer, runs all the declared tests, and asserts that
/// they pass.
///
/// This is typically used to run multiple tests where later tests make
/// assertions about the results of previous ones.
Future expectTestsPass(void body()) async {
  var engine = declareEngine(body);
  var success = await engine.run();

  for (var test in engine.liveTests) {
    expectTestPassed(test);
  }

  expect(success, isTrue);
}

/// Runs [body] with a declarer and returns the declared entries.
List<GroupEntry> declare(void body()) {
  var declarer = Declarer()..declare(body);
  return declarer.build().entries;
}

/// Runs [body] with a declarer and returns an engine that runs those tests.
Engine declareEngine(void body(), {bool runSkipped = false}) {
  var declarer = Declarer()..declare(body);
  return Engine.withSuites([
    RunnerSuite(
        const PluginEnvironment(),
        SuiteConfiguration(runSkipped: runSkipped),
        declarer.build(),
        suitePlatform)
  ]);
}

/// Returns a [RunnerSuite] with a default environment and configuration.
RunnerSuite runnerSuite(Group root) => RunnerSuite(
    const PluginEnvironment(), SuiteConfiguration.empty, root, suitePlatform);

/// Whether Pub is running with Dart 2 runtime semantics.
final bool isDart2 = () {
  Type checkType<T>() => T;
  return checkType<String>() == String;
}();
