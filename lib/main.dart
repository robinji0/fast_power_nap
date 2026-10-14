import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nap_home_page.dart';

/// 应用入口
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 锁定竖屏：午休时手机平放，避免横竖屏切换造成干扰
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  // 状态栏/导航栏沉浸式暗色
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0xFF05070D),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const PowerNapApp());
}

/// 根组件：配置全局暗黑主题
class PowerNapApp extends StatelessWidget {
  const PowerNapApp({super.key});

  // 主色调：柔和的靛蓝色，夜间不刺眼
  static const Color accent = Color(0xFF7C9CFF);
  static const Color background = Color(0xFF05070D);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Power Nap AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: background,
        ),
        textTheme: Typography.whiteMountainView.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.white54),
        ),
      ),
      home: const NapHomePage(),
    );
  }
}
