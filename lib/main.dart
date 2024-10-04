import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:webrtc_video_call/push_notification_server_key.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize Firebase Messaging and Notifications
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  AwesomeNotifications().initialize(
    null,
    [
      NotificationChannel(
        channelKey: 'call_channel',
        channelName: 'Call Notifications',
        channelDescription: 'Notifications for incoming calls',
        defaultColor: const Color(0xFF9D50DD),
        ledColor: Colors.white,
        importance: NotificationImportance.High,
        defaultRingtoneType: DefaultRingtoneType.Ringtone,
        locked: true,
      )
    ],
  );

  runApp(const MyApp());
}

// Firebase messaging background handler
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  showIncomingCallNotification(message.data['callerName']);
}

// Function to show incoming call notification
void showIncomingCallNotification(String callerName) {
  AwesomeNotifications().createNotification(
    content: NotificationContent(
      id: 1234,
      channelKey: 'call_channel',
      title: 'Incoming Call',
      body: 'Incoming video call from $callerName',
      notificationLayout: NotificationLayout.Default,
      wakeUpScreen: true,
      fullScreenIntent: true,
      category: NotificationCategory.Call,
    ),
    actionButtons: [
      NotificationActionButton(key: 'ACCEPT', label: 'Accept', color: Colors.green),
      NotificationActionButton(key: 'REJECT', label: 'Reject', color: Colors.red),
    ],
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter WebRTC Call',
      home: const AuthScreen(),
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  _AuthScreenState createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  void login() async {
    try {
      await _auth.signInWithEmailAndPassword(
          email: emailController.text, password: passwordController.text);
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (context) => const HomeScreen()));
    } catch (e) {
      print('Error logging in: $e');
    }
  }

  void register() async {
    try {
      await _auth.createUserWithEmailAndPassword(
          email: emailController.text, password: passwordController.text);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_auth.currentUser?.uid)
          .set({'email': emailController.text, 'uid': _auth.currentUser?.uid});
      login();
    } catch (e) {
      print('Error registering: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login/Register')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(controller: emailController, decoration: const InputDecoration(hintText: 'Email')),
            TextField(controller: passwordController, decoration: const InputDecoration(hintText: 'Password')),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton(onPressed: login, child: const Text('Login')),
                ElevatedButton(onPressed: register, child: const Text('Register')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  String? fcmToken;

  @override
  void initState() {
    super.initState();

    // Configure FCM and store the FCM token in Firestore
    FirebaseMessaging.instance.getToken().then((token) {
      fcmToken = token;
      print('FCM Token: $fcmToken');  // Print FCM token when received

      // Store the FCM token in Firestore for the current user
      if (_auth.currentUser != null && fcmToken != null) {
        FirebaseFirestore.instance
            .collection('users')
            .doc(_auth.currentUser?.uid)
            .update({'fcmToken': fcmToken});
      }
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      String callerName = message.data['callerName'] ?? 'Unknown Caller';
      print('Message received: $callerName');
      showIncomingCallNotification(callerName);
    });

    // Listen to notification action streams
    AwesomeNotifications().setListeners(
      onActionReceivedMethod: (ReceivedAction action) async {
        if (action.buttonKeyPressed == "REJECT") {
          print("Call rejected");
        } else if (action.buttonKeyPressed == "ACCEPT") {
          print("Call accepted");
        } else {
          print("Clicked on notification");
        }
      },
    );
  }

  void initiateCall(String uid, String peerEmail) async {
    final callId = FirebaseFirestore.instance.collection('calls').doc().id;
    Navigator.push(
        context, MaterialPageRoute(builder: (context) => CallScreen(callId: callId, isCaller: true, peerId: uid)));

    // Retrieve the recipient's FCM token from Firestore
    DocumentSnapshot userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    String? peerFcmToken = userDoc['fcmToken'];

    if (peerFcmToken == null) {
      print('No FCM token found for the user: $peerEmail');
      return;
    }

    // Print debug message and send push notification using FCM
    print('Sending push notification to: $peerEmail (UID: $uid) with FCM token: $peerFcmToken');

    // Get access token from service account
    String accessToken = await PushNotificationServerKey.getAccessToken();
    print("Access Token: $accessToken");

    // Send push notification via FCM
    await sendPushNotification(accessToken, peerFcmToken, callId);
  }

  Future<void> sendPushNotification(String accessToken, String fcmToken, String callId) async {
    try {
      final response = await http.post(
        Uri.parse("https://fcm.googleapis.com/v1/projects/push-474fb/messages:send"),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(
          <String, dynamic>{
            'message': {
              'notification': {
                'title': "Incoming Call",
                'body': "You have an incoming call",
              },
              'token': fcmToken,  // Use the recipient's FCM token
              'data': {
                'callerId': _auth.currentUser?.uid,
                'callId': callId,
                "callerName": _auth.currentUser?.email ?? "Unknown Caller",
              },
            },
          },
        ),
      );

      if (response.statusCode == 200) {
        print("Notification sent successfully");
      } else {
        print("Failed to send notification: ${response.body}");
      }
    } catch (e) {
      print("Error sending push notification: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Logged In: ${_auth.currentUser?.email}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await _auth.signOut();
              Navigator.pushReplacement(
                  context, MaterialPageRoute(builder: (context) => const AuthScreen()));
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          var users = snapshot.data!.docs;
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              var user = users[index];
              return ListTile(
                title: Text(user['email']),
                trailing: IconButton(
                  icon: const Icon(Icons.call),
                  onPressed: () {
                    initiateCall(user['uid'], user['email']);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class CallScreen extends StatefulWidget {
  final String callId;
  final bool isCaller;
  final String peerId;

  const CallScreen({super.key, required this.callId, required this.isCaller, required this.peerId});

  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  void initState() {
    super.initState();
    initRenderers();
    startCall();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection?.close();
    super.dispose();
  }

  void initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> startCall() async {
    final Map<String, dynamic> configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };

    _peerConnection = await createPeerConnection(configuration);

    // Listen for ICE candidates and update Firestore
    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) async {
      if (widget.isCaller) {
        await _firestore.collection('calls').doc(widget.callId).set({
          'callerIceCandidates': [],
          'calleeIceCandidates': [],
          'offer': null,
          'answer': null,
        }, SetOptions(merge: true));  // Create or merge the document

        await _firestore.collection('calls').doc(widget.callId).update({
          'callerIceCandidates': FieldValue.arrayUnion([candidate.toMap()])
        });
      } else {
        await _firestore.collection('calls').doc(widget.callId).set({
          'callerIceCandidates': [],
          'calleeIceCandidates': [],
          'offer': null,
          'answer': null,
        }, SetOptions(merge: true));  // Create or merge the document

        await _firestore.collection('calls').doc(widget.callId).update({
          'calleeIceCandidates': FieldValue.arrayUnion([candidate.toMap()])
        });
      }
    };

    _peerConnection?.onAddStream = (MediaStream stream) {
      _remoteRenderer.srcObject = stream;
    };

    if (widget.isCaller) {
      final offer = await _peerConnection?.createOffer();
      await _peerConnection?.setLocalDescription(offer!);

      await _firestore.collection('calls').doc(widget.callId).set({
        'offer': offer?.toMap(),
        'callerIceCandidates': [],
        'calleeIceCandidates': [],
        'answer': null,
      }, SetOptions(merge: true));  // Create or merge the document
    } else {
      _firestore.collection('calls').doc(widget.callId).snapshots().listen((callDoc) async {
        if (callDoc.exists && callDoc.data()?['offer'] != null) {
          await _peerConnection?.setRemoteDescription(
              RTCSessionDescription(callDoc.data()?['offer']['sdp'], callDoc.data()?['offer']['type']));
          final answer = await _peerConnection?.createAnswer();
          await _peerConnection?.setLocalDescription(answer!);

          await _firestore.collection('calls').doc(widget.callId).set({
            'answer': answer?.toMap(),
          }, SetOptions(merge: true));  // Create or merge the document
        }

        if (callDoc.data()?['callerIceCandidates'] != null) {
          for (var iceCandidate in callDoc.data()?['callerIceCandidates']) {
            await _peerConnection?.addCandidate(
              RTCIceCandidate(iceCandidate['candidate'], iceCandidate['sdpMid'], iceCandidate['sdpMLineIndex']),
            );
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call'),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_end),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          RTCVideoView(_remoteRenderer), // Display remote video
          Align(
            alignment: Alignment.topLeft,
            child: RTCVideoView(_localRenderer), // Display local video
          ),
        ],
      ),
    );
  }
}
