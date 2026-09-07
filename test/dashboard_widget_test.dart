import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/screens/home_shell.dart';
import 'package:dart_control_panel/widgets/state_dashboard.dart';

DaemonState _fixtureState() {
  final raw = File('test/fixtures/payloads/state_envelope_full.json')
      .readAsStringSync();
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
  testWidgets('renders all major sections from the full fixture',
      (tester) async {
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
    expect(find.text('nv21_score'), findsOneWidget);

    // uart
    expect(find.text('UART'), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
    expect(find.text('12400..13000'), findsOneWidget);

    // stream / recording
    expect(find.text('RTSP / Recording'), findsOneWidget);
    expect(find.text('on :8554'), findsOneWidget);

    // view/control
    expect(find.text('View / Control'), findsOneWidget);
  });

  testWidgets('highlights requested/actual ISP difference in error color',
      (tester) async {
    final state = _fixtureState();
    await _pumpDashboard(tester, state);

    // exposure requested=1000 actual=999 -> mismatch -> error color bold
    final actualText = tester.widget<Text>(find.text('999'));
    final style = actualText.style!;
    expect(style.color, ThemeData.light().colorScheme.error);
    expect(style.fontWeight, FontWeight.bold);
  });

  testWidgets('transitional state shows the transition banner',
      (tester) async {
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

    expect(find.text('Transitioning: STANDBY_PENDING → full_square_360'),
        findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
  });

  testWidgets('transitional daemon state is flagged in the daemon card',
      (tester) async {
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

  testWidgets('missing worker renders daemon card only, no crash',
      (tester) async {
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
      await tester.pumpWidget(const MaterialApp(home: HomeShell()));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Telemetry'), findsWidgets);
      expect(find.text('Ground Test'), findsWidgets);
      expect(find.text('Mode'), findsWidgets);
      expect(find.text('Files'), findsWidgets);
    });

    testWidgets('uses NavigationBar on narrow windows', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: HomeShell()));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('switching pages keeps one shared connection', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: HomeShell()));
      // Mode page shows the shared "not connected" hint, not its own Connect
      await tester.tap(find.text('Mode'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connect once'), findsOneWidget);
      // back to telemetry
      await tester.tap(find.text('Telemetry'));
      await tester.pumpAndSettle();
      expect(find.text('Attitude (dummy)'), findsOneWidget);
    });
  });
}
