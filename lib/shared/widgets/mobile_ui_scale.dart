import 'package:flutter/material.dart';

/// Scale the complete handset viewport, including routes and dialogs, rather
/// than shrinking text alone. Desktop and tablet layouts remain unchanged.
class MobileUiScale extends StatelessWidget {
  const MobileUiScale({super.key, required this.child});

  static const handsetScale = .85;
  final Widget child;

  static bool isHandset(BuildContext context) {
    final platform = Theme.of(context).platform;
    final scale =
        context.dependOnInheritedWidgetOfExactType<_ScaleScope>()?.scale ?? 1;
    return (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        MediaQuery.sizeOf(context).shortestSide * scale < 600;
  }

  @override
  Widget build(BuildContext context) {
    if (!isHandset(context)) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final media = MediaQuery.of(context);
        final size = Size(
          constraints.maxWidth / handsetScale,
          constraints.maxHeight / handsetScale,
        );
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: size,
            child: _ScaleScope(
              scale: handsetScale,
              child: MediaQuery(
                data: media.copyWith(
                  size: size,
                  padding: media.padding / handsetScale,
                  viewPadding: media.viewPadding / handsetScale,
                  viewInsets: media.viewInsets / handsetScale,
                  systemGestureInsets: media.systemGestureInsets / handsetScale,
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    appBarTheme: Theme.of(context).appBarTheme.copyWith(
                      toolbarHeight: 28,
                      titleSpacing: 8,
                      titleTextStyle: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScaleScope extends InheritedWidget {
  const _ScaleScope({required this.scale, required super.child});

  final double scale;

  @override
  bool updateShouldNotify(_ScaleScope oldWidget) => scale != oldWidget.scale;
}
