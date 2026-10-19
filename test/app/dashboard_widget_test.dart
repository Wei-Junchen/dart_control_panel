import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/preferences/connection_settings.dart';

import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/app/home_shell.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/shared/widgets/state_dashboard.dart';

DaemonState _fixtureState() {
  final raw = File(
    'test/fixtures/payloads/state_envelope_full.json',
  ).readAsStringSync();
  return DaemonState.fromEnvelope(jsonDecode(raw) as Map<String, dynamic>);
}

Future<void> _pumpDashboard(WidgetTester tester, DaemonState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: StateDashboard(state: state)),
    ),
  );
}

void main() {
  testWidgets('renders all major sections from the full fixture', (
    tester,
  ) async {
    await _pumpDashboard(tester, _fixtureState());

    // daemon card
    expect(find.text('Daemon'), findsOneWidget);
    expect(find.text('STREAMING'), findsOneWidget);
    // profile appears in the Daemon card and the View/Control card
    expect(find.text('full_wide_640x360'), findsNWidgets(2));
    expect(find.text('184'), findsOneWidget);

    // performance
    expect(find.text('Performance'), findsOneWidget);
    expect(find.text('79.8 / 80'), findsOneWidget);
    expect(find.text('detection fps'), findsOneWidget);

    // target
    expect(find.text('Target'), findsOneWidget);
    expect(find.text('FOUND'), findsOneWidget);
    expect(find.text('(180, 120)'), findsOneWidget);

    // ISP side-by-side requested vs actual
    expect(find.text('ISP — requested vs actual'), findsOneWidget);
    expect(find.text('Requested'), findsOneWidget);
    expect(find.text('Actual (isp)'), findsOneWidget);
    expect(find.text('exposure us'), findsOneWidget);
    expect(find.text('1000'), findsOneWidget); // requested
    expect(find.text('999'), findsOneWidget); // actual readback (diff)

    // resources / hardware
    expect(find.text('Hardware / Features'), findsOneWidget);
    expect(find.text('51.2 °C'), findsOneWidget);

    // vision
    expect(find.text('Vision'), findsOneWidget);
    expect(find.text('NV21 green'), findsOneWidget);

    // uart
    expect(find.text('UART'), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
    expect(find.text('12400..13000'), findsOneWidget);

    // stream encoder
    expect(find.text('RTSP encoder'), findsOneWidget);
    expect(find.text('on :8554'), findsOneWidget);

    // view/control
    expect(find.text('View / Control'), findsOneWidget);
  });

  testWidgets('highlights requested/actual ISP difference in error color', (
    tester,
  ) async {
    final state = _fixtureState();
    await _pumpDashboard(tester, state);

    // exposure requested=1000 actual=999 -> mismatch -> error color bold
    final actualText = tester.widget<Text>(find.text('999'));
    final style = actualText.style!;
    expect(style.color, ThemeData.light().colorScheme.error);
    expect(style.fontWeight, FontWeight.bold);
  });

  testWidgets('transitional state shows the transition banner', (tester) async {
    final base = _fixtureState();
    final transitional = DaemonState.fromEnvelope({
      'v': 1,
      'payload': {
        ...base.envelope['payload'] as Map<String, dynamic>,
        'state': 'STANDBY_PENDING',
        'pending_profile': 'full_square_360',
      },
    });
    await _pumpDashboard(tester, transitional);

    expect(
      find.text('Transitioning: STANDBY_PENDING → full_square_360'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsWidgets);
  });

  testWidgets('transitional daemon state is flagged in the daemon card', (
    tester,
  ) async {
    final base = _fixtureState();
    final waking = DaemonState.fromEnvelope({
      'v': 1,
      'payload': {
        ...base.envelope['payload'] as Map<String, dynamic>,
        'state': 'WAKING',
      },
    });
    expect(waking.isTransitional, isTrue);
    expect(DaemonState.isTransitionalState('WAKING'), isTrue);
    expect(DaemonState.isTransitionalState('STREAMING'), isFalse);
  });

  testWidgets('missing worker renders daemon card only, no crash', (
    tester,
  ) async {
    final state = DaemonState.fromEnvelope({
      'v': 1,
      'payload': {'state': 'STOPPED'},
    });
    await _pumpDashboard(tester, state);
    expect(find.text('Daemon'), findsOneWidget);
    expect(find.text('STOPPED'), findsOneWidget);
    expect(find.text('Performance'), findsNothing);
  });

  group('HomeShell responsive navigation', () {
    testWidgets('uses NavigationRail on wide windows', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            enableAutoDiscovery: false,
            connectionSettingsStore: ConnectionSettingsStore.memory(),
          ),
        ),
      );
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Telemetry'), findsWidgets);
      expect(find.text('Ground Test'), findsWidgets);
      expect(find.text('Mode'), findsWidgets);
      expect(find.text('Logs'), findsWidgets);
      expect(find.widgetWithText(TextField, 'Port'), findsNothing);
      expect(find.widgetWithText(TextField, 'Board IP'), findsNothing);
      expect(find.text('高级连接'), findsOneWidget);
    });

    testWidgets('uses NavigationBar on narrow windows', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            enableAutoDiscovery: false,
            connectionSettingsStore: ConnectionSettingsStore.memory(),
          ),
        ),
      );
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('switching pages keeps one shared connection', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            enableAutoDiscovery: false,
            connectionSettingsStore: ConnectionSettingsStore.memory(),
          ),
        ),
      );
      // Mode page shows the shared "not connected" hint, not its own Connect
      await tester.tap(find.text('Mode'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请先连接开发板'), findsOneWidget);
      // back to telemetry
      await tester.tap(find.text('Telemetry'));
      await tester.pumpAndSettle();
      expect(find.text('Attitude (UDP UART)'), findsOneWidget);
    });

    testWidgets(
      'desktop exit request waits for connection record finalization',
      (tester) async {
        late Directory root;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('exit-record-');
        });
        final source = _LifecycleTelemetrySource();
        final recorder = TelemetryRecorder(directory: root);
        final telemetry = TelemetryController(
          source: source,
          recorder: recorder,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: HomeShell(
              telemetryController: telemetry,
              enableAutoDiscovery: false,
              connectionSettingsStore: ConnectionSettingsStore.memory(),
            ),
          ),
        );
        await tester.runAsync(
          () => telemetry.beginConnection('mock-board:9000'),
        );
        source.emit(1);
        await tester.runAsync(() async {
          await TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage(
                'flutter/platform',
                const JSONMethodCodec().encodeMethodCall(
                  const MethodCall('System.requestAppExit'),
                ),
                (_) {},
              );
          expect(recorder.sessionActive, false);
          final saved = await TelemetryArchive.open(recorder.sessionDirectory!);
          expect(saved.rows, 1);
          expect(saved.metadata['complete'], true);
          final endedAt = saved.metadata['ended_at'];
          await recorder.close();
          final reopened = await TelemetryArchive.open(
            recorder.sessionDirectory!,
          );
          expect(reopened.metadata['complete'], true);
          expect(reopened.metadata['ended_at'], endedAt);
        });
        await tester.pumpWidget(const SizedBox());
        telemetry.dispose();
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
          await root.delete(recursive: true);
        });
      },
    );

    testWidgets('switching pages never stops the application UDP receiver', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final source = _LifecycleTelemetrySource();
      final telemetry = TelemetryController(source: source);
      addTearDown(telemetry.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            telemetryController: telemetry,
            enableAutoDiscovery: false,
            connectionSettingsStore: ConnectionSettingsStore.memory(),
          ),
        ),
      );
      await tester.runAsync(() => telemetry.beginConnection('mock-board:9000'));
      expect(source.startCalls, 1);
      source.emit(1);
      expect(telemetry.samples, hasLength(1));

      await tester.tap(find.text('Ground Test'));
      await tester.pumpAndSettle();
      source.emit(2);
      expect(source.stopCalls, 0);
      expect(telemetry.samples, hasLength(2));

      await tester.tap(find.text('Mode'));
      await tester.pumpAndSettle();
      source.emit(3);
      expect(source.stopCalls, 0);
      expect(telemetry.samples, hasLength(3));

      await tester.tap(find.text('Telemetry'));
      await tester.pumpAndSettle();
      expect(source.startCalls, 1);
      expect(telemetry.samples, hasLength(3));
    });
  });
}

class _LifecycleTelemetrySource implements TelemetrySource {
  int startCalls = 0;
  int stopCalls = 0;
  void Function(TelemetrySample)? _listener;

  @override
  String get label => 'lifecycle-test';

  @override
  void start(void Function(TelemetrySample sample) onSample) {
    startCalls++;
    _listener = onSample;
  }

  void emit(int value) => _listener?.call(
    TelemetrySample(time: DateTime.now(), values: {'pitch': value.toDouble()}),
  );

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}
