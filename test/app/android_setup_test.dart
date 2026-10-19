import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/preferences/connection_settings.dart';
import 'package:dart_control_panel/app/home_shell.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';

class SilentSource implements TelemetrySource {
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) onSample) {}
  @override
  Future<void> stop() async {}
}

void main() {
  test(
    'Android release declares network access, landscape and no broad storage permission',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android.permission.INTERNET'));
      expect(manifest, contains('android:screenOrientation="sensorLandscape"'));
      expect(manifest, contains('android:usesCleartextTraffic="true"'));
      expect(manifest, isNot(contains('MANAGE_EXTERNAL_STORAGE')));
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('applicationIdSuffix = ".debug"'));
    },
  );
  test(
    'ZIP sharing exposes only cache exports through a non-public provider',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('androidx.core.content.FileProvider'));
      expect(manifest, contains(r'${applicationId}.logshare'));
      final paths = File(
        'android/app/src/main/res/xml/log_share_paths.xml',
      ).readAsStringSync();
      expect(paths, contains('path="log_shares/"'));
      expect(paths, isNot(contains('<external-path')));
      expect(paths, isNot(contains('<root-path')));
      final native = File(
        'android/app/src/main/kotlin/com/litwei/dart_control_panel/MainActivity.kt',
      ).readAsStringSync();
      expect(native, contains('Intent.ACTION_SEND'));
      expect(native, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
      expect(native, isNot(contains('Intent.FLAG_GRANT_WRITE_URI_PERMISSION')));
      expect(native, contains('ClipData.newRawUri'));
    },
  );

  for (final size in [
    const Size(800, 363),
    const Size(844, 390),
    const Size(960, 540),
  ]) {
    testWidgets('landscape tester UI fits $size without overflow', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = TelemetryController(source: SilentSource());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          builder: (context, child) => MobileUiScale(child: child!),
          home: HomeShell(
            telemetryController: controller,
            enableAutoDiscovery: false,
            connectionSettingsStore: ConnectionSettingsStore.memory(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Telemetry'), findsWidgets);
      expect(find.byType(NavigationRail), findsNothing);
      final railFinder = find.byKey(const ValueKey('mobile-navigation'));
      final paintedWidth =
          tester.getTopRight(railFinder).dx - tester.getTopLeft(railFinder).dx;
      expect(paintedWidth, closeTo(34, .1));
      final icons = tester.widgetList<Icon>(
        find.descendant(of: railFinder, matching: find.byType(Icon)),
      );
      expect(icons.length, 5);
      expect(icons.every((icon) => icon.size == 22), isTrue);
      final sidebar = find.byKey(const ValueKey('telemetry-channel-sidebar'));
      expect(sidebar, findsOneWidget);
      expect(
        find.byKey(const ValueKey('telemetry-channel-search')),
        findsOneWidget,
      );
      final chart = find.byType(TelemetryChart);
      expect(
        tester.getRect(sidebar).left,
        greaterThan(tester.getRect(chart).right),
      );
      expect(tester.getRect(chart).height, greaterThan(140));
      expect(tester.getRect(sidebar).width, lessThan(200));
      final search = find.byKey(const ValueKey('telemetry-channel-search'));
      expect(tester.getRect(search).height, lessThanOrEqualTo(32));
      expect(find.byKey(const ValueKey('chart-touch-probe')), findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.text('Board IP'), findsNothing);
      await tester.tap(find.byTooltip('Board Connect'));
      await tester.pumpAndSettle();
      expect(find.text('高级连接'), findsOneWidget);
      expect(find.text('Board IP'), findsNothing);
      await tester.tap(find.text('高级连接'));
      await tester.pumpAndSettle();
      expect(find.text('Board IP'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('姿态与目标'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      for (final destination in ['Ground Test', 'Mode', 'Telemetry']) {
        await tester.tap(find.byTooltip(destination));
        await tester.pumpAndSettle();
        final header = tester.widget<AppBar>(find.byType(AppBar));
        final headerContext = tester.element(find.byType(AppBar));
        expect(
          header.toolbarHeight ??
              Theme.of(headerContext).appBarTheme.toolbarHeight,
          28,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip('Logs'));
      await tester.pumpAndSettle();
      expect(find.text('飞行日志'), findsOneWidget);
      expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 28);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('本地副本 / 回放'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  }
}
