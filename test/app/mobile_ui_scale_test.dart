import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform handset scales geometry and keeps taps aligned', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late MediaQueryData effective;
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(left: 24),
              viewPadding: const EdgeInsets.only(left: 24),
              viewInsets: const EdgeInsets.only(bottom: 100),
              textScaler: TextScaler.linear(1.2),
            ),
            child: MobileUiScale(child: child!),
          ),
          home: Builder(
            builder: (context) {
              effective = MediaQuery.of(context);
              expect(MobileUiScale.isHandset(context), isTrue);
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => tapped = true,
                    child: const Text('Tap scaled control'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(effective.size.width, closeTo(844 / .85, .01));
      expect(effective.size.height, closeTo(390 / .85, .01));
      expect(effective.padding.left, closeTo(24 / .85, .01));
      expect(effective.viewInsets.bottom, closeTo(100 / .85, .01));
      expect(effective.textScaler.scale(10), closeTo(12, .01));
      await tester.tap(find.text('Tap scaled control'));
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (TargetPlatform.linux, const Size(844, 390)),
    (TargetPlatform.android, const Size(1280, 800)),
  ]) {
    testWidgets('${scenario.$1} ${scenario.$2} keeps original viewport', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(scenario.$2);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = scenario.$2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late Size effective;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: scenario.$1),
          builder: (context, child) => MobileUiScale(child: child!),
          home: Builder(
            builder: (context) {
              effective = MediaQuery.sizeOf(context);
              return const Scaffold(body: Text('Original size'));
            },
          ),
        ),
      );
      expect(effective, scenario.$2);
      expect(find.byType(FittedBox), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
