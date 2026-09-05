import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:system_theme/system_theme.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/home_screen.dart';
import 'services/notification_service.dart';
import 'services/portable_mode.dart';
import 'services/tray_service.dart';
import 'services/window_state_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Must come before anything that touches SharedPreferences — the first read
  // caches the file, so a later redirect would be ignored. WindowStateService
  // .restore() below is the first such caller.
  PortableMode.init();
  // Must come before any windowManager call — TrayService registers a
  // WindowListener during init().
  await windowManager.ensureInitialized();
  // Lock the window to a square. Handled natively in WM_SIZING, so it only
  // constrains drag-resizes — the runner default, the restored size and the
  // resize floor all have to be square in their own right to match.
  await windowManager.setAspectRatio(1);
  // Aero Snap and maximise resize through WM_SIZE, which the aspect-ratio lock
  // never sees, so either would leave a non-square window. Dropping
  // WS_MAXIMIZEBOX turns off both (Windows gates snapping on that style).
  await windowManager.setMaximizable(false);
  // Floor for manual resizing. The default size lives in windows/runner/
  // main.cpp; this stops the window being dragged below what the mini-player
  // and the sign-in form can render. Must precede restore() so a stale saved
  // size can't land under the floor.
  await windowManager.setMinimumSize(
    const Size(
      WindowStateService.minSide,
      WindowStateService.minSide,
    ),
  );
  // Runs while the window is still hidden — see WindowStateService.restore.
  await WindowStateService.instance.restore();
  await SystemTheme.accentColor.load();
  await NotificationService.instance.init();
  try {
    await acrylic.Window.initialize();
    await acrylic.Window.setEffect(effect: acrylic.WindowEffect.mica);
  } catch (_) {
    // Mica not available on older Windows — falls back to opaque background.
  }
  await TrayService.instance.init();
  WindowStateService.instance.startTracking();
  runApp(const EncoreApp());
}

class EncoreApp extends StatelessWidget {
  const EncoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'encore for rocksky',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: FluentThemeData(
        accentColor: SystemTheme.accentColor.accent.toAccentColor(),
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      darkTheme: FluentThemeData(
        accentColor: SystemTheme.accentColor.accent.toAccentColor(),
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const HomeScreen(),
    );
  }
}
