import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'core/session.dart';
import 'screens/add_phone_screen.dart';
import 'screens/home_screen.dart';
import 'screens/incident_screen.dart';
import 'screens/login_screen.dart';
import 'screens/share_screen.dart';
import 'services/purchases_service.dart';
import 'services/subscription_controller.dart';
import 'socket/haven_socket.dart';
import 'socket/live_chat_socket.dart';
import 'socket/live_location_socket.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HavenSocket.instance.onAuthRejected = Session.instance.refresh;
  await Session.instance.load();
  await PurchasesService.instance.configure(userId: Session.instance.userId);
  SubscriptionController.instance.init();
  runApp(const HavenApp());
}

/// Connects the socket with the current access token. The token is read on
/// every (re)connect, so refreshed tokens are picked up automatically.
void connectSocket() {
  HavenSocket.instance.connect(
    kBaseUrl,
    kWsNamespace,
    () => Session.instance.accessToken ?? '',
  );
}

class HavenApp extends StatefulWidget {
  const HavenApp({super.key});

  @override
  State<HavenApp> createState() => _HavenAppState();
}

class _HavenAppState extends State<HavenApp> with WidgetsBindingObserver {
  final _subs = <StreamSubscription>[];
  bool _wasLoggedIn = false;
  Type? _root;

  @override
  void initState() {
    super.initState();
    final socket = HavenSocket.instance;

    // Always-on listeners: circle invites arrive in the user room before
    // any subscribe, so they are handled app-wide rather than per screen.
    _subs
      ..add(socket.incidentTriggered.listen(_onIncidentTriggered))
      ..add(socket.shareStarted.listen(_onShareStarted))
      ..add(socket.exceptions.listen((e) => _toast('${e.code}: ${e.message}')));

    Session.instance.addListener(_onSessionChanged);
    _wasLoggedIn = Session.instance.isLoggedIn;
    _root = _rootScreen().runtimeType;
    if (_wasLoggedIn) {
      connectSocket();
      Session.instance.syncUser(); // may reroute to/from AddPhoneScreen
      SubscriptionController.instance.onResume();
    }
    SubscriptionController.instance.onNotice = _toast;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    Session.instance.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Login when signed out, AddPhoneScreen while the account has no phone
  /// (Google sign-in), else Home.
  static Widget _rootScreen() {
    final session = Session.instance;
    if (!session.isLoggedIn) return const LoginScreen();
    if (session.needsPhone) return const AddPhoneScreen();
    return const HomeScreen();
  }

  void _onSessionChanged() {
    final loggedIn = Session.instance.isLoggedIn;
    if (loggedIn != _wasLoggedIn) {
      _wasLoggedIn = loggedIn;
      if (loggedIn) {
        connectSocket();
        // RevenueCat app user ID = our user ID, so webhooks map to our user.
        final userId = Session.instance.userId;
        if (userId != null) SubscriptionController.instance.onLogin(userId);
      }
    }
    final root = _rootScreen().runtimeType;
    if (root == _root) return;
    _root = root;
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => _rootScreen()),
      (_) => false,
    );
  }

  void _onIncidentTriggered(Map<String, dynamic> data) {
    final incidentId = data['incidentId']?.toString();
    if (incidentId == null) return;
    if (data['ownerUserId'] != null && data['ownerUserId'] == Session.instance.userId) return;
    messengerKey.currentState?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 30),
      backgroundColor: Colors.red.shade700,
      content: const Text('SOS from a circle member'),
      action: SnackBarAction(
        label: 'OPEN',
        textColor: Colors.white,
        onPressed: () => navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (_) => IncidentScreen(incidentId: incidentId, isOwner: false),
        )),
      ),
    ));
  }

  void _onShareStarted(Map<String, dynamic> data) {
    final shareId = (data['shareId'] ?? data['id'])?.toString();
    if (shareId == null) return;
    messengerKey.currentState?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: const Text('Someone is sharing their live location'),
      action: SnackBarAction(
        label: 'VIEW',
        onPressed: () => navigatorKey.currentState?.push(MaterialPageRoute(
          builder: (_) => ShareScreen(shareId: shareId, isOwner: false),
        )),
      ),
    ));
  }

  /// Syncs the subscription on foreground: forced after the store page,
  /// else throttled.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SubscriptionController.instance.onResume();
  }

  void _toast(String text) =>
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haven',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: _rootScreen(),
    );
  }
}
