import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'chatbot_gemini_service.dart';

class ChatbotScreen extends StatefulWidget {
  const ChatbotScreen({super.key});

  @override
  State<ChatbotScreen> createState() => _ChatbotScreenState();
}

class _ChatbotScreenState extends State<ChatbotScreen> {
  final ChatbotGeminiService _service = ChatbotGeminiService();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  // Conversation history shown in the UI; index 0 is always the welcome message.
  final List<_Message> _messages = [
    const _Message(
      role: _Role.assistant,
      text:
          'اهلا! انا مساعد تنسيق الملابس. اسألني عن تنسيق القطع، الالوان، الاطلالات، والخامات المناسبة.',
    ),
  ];

  bool _sending = false;

  /// Quick-reply chips shown above the input bar.
  static const List<String> _examples = [
    'نسقلي قميص ابيض بشكل كاجوال.',
    'ايه افضل الالوان للبشرة القمحية؟',
    'عايز اوتفيت شتوي مناسب للشغل.',
    'افضل خامات للجو الحر ايه؟',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Sends a message, either typed by the user or tapped from [_examples].
  Future<void> _send([String? preset]) async {
    final text = (preset ?? _controller.text).trim();
    if (text.isEmpty || _sending) return;

    _controller.clear();
    FocusScope.of(context).unfocus();

    setState(() {
      _messages.add(_Message(role: _Role.user, text: text));
      _sending = true;
    });
    _jumpToBottom();

    try {
      final contents = _buildContentsWithHistory(userMessage: text);
      final reply = await _service.chat(
        contents: contents,
        systemPrompt: _systemPrompt,
      );

      if (!mounted) return;
      setState(() {
        _messages.add(_Message(role: _Role.assistant, text: reply));
      });
    } catch (e) {
      // ignore: avoid_print
      print('[ChatbotScreen] chat error: $e');
      if (e is ChatbotGeminiException && e.attemptTrace.isNotEmpty) {
        // ignore: avoid_print
        print('[ChatbotScreen] attempt trace:');
        for (final step in e.attemptTrace) {
          // ignore: avoid_print
          print('[ChatbotScreen] $step');
        }
      }
      if (!mounted) return;
      setState(() {
        _messages.add(
          _Message(
            role: _Role.assistant,
            text: _friendlyError(e),
          ),
        );
      });
    } finally {
      if (!mounted) return;
      setState(() => _sending = false);
      _jumpToBottom();
    }
  }

  /// Builds the `contents` list sent to Gemini, including recent history.
  ///
  /// Skips the welcome message (index 0) and caps history at 18 turns to
  /// stay within the model's context window without sending stale context.
  List<Map<String, dynamic>> _buildContentsWithHistory({
    required String userMessage,
  }) {
    final history = <Map<String, dynamic>>[];
    for (final m in _messages.skip(1).take(18)) {
      history.add({
        'role': m.role == _Role.assistant ? 'model' : 'user',
        'parts': [
          {'text': m.text},
        ],
      });
    }

    history.add({
      'role': 'user',
      'parts': [
        {'text': userMessage},
      ],
    });

    return history;
  }

  /// Formats a caught exception into a user-visible message that also
  /// includes debug detail (status, model, key suffix, raw snippet, recent
  /// attempt trace) to aid diagnosis without leaving the app.
  String _friendlyError(Object e) {
    if (e is ChatbotGeminiException) {
      final lines = <String>[
        _friendlyTitleForError(e),
        '',
        'DEBUG:',
        'reason: ${e.message}',
        'status: ${e.statusCode ?? 'n/a'}',
        'model: ${e.model ?? 'n/a'}',
        'key: ${e.keySuffix ?? 'n/a'}',
      ];

      final raw = (e.raw ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (raw.isNotEmpty) {
        final snippet = raw.length > 220 ? '${raw.substring(0, 220)}...' : raw;
        lines.add('raw: $snippet');
      }

      // Show only the last 10 attempt steps to keep the message readable.
      if (e.attemptTrace.isNotEmpty) {
        final start = e.attemptTrace.length > 10 ? e.attemptTrace.length - 10 : 0;
        final recent = e.attemptTrace.sublist(start);
        lines.add('recent attempts:');
        lines.addAll(recent);
      }

      return lines.join('\n');
    }

    return 'تعذر الحصول على رد.\n\nDEBUG: ${e.toString()}';
  }

  /// Returns an Arabic user-facing title for the error based on its cause.
  String _friendlyTitleForError(ChatbotGeminiException e) {
    final reason = e.message.toLowerCase();
    if (reason.contains('all configured gemini keys are invalid')) {
      return 'تعذر الحصول على رد لأن كل مفاتيح Gemini غير صالحة.';
    }
    if ((e.statusCode ?? 0) == 429 || reason.contains('quota')) {
      return 'تعذر الحصول على رد الآن بسبب ضغط/حصة Gemini. حاول بعد دقائق.';
    }
    return 'تعذر الحصول على رد.';
  }

  /// Resets the conversation to a single welcome message.
  void _newChat() {
    setState(() {
      _messages
        ..clear()
        ..add(
          const _Message(
            role: _Role.assistant,
            text: 'بدأنا محادثة جديدة. اسألني اي سؤال عن الملابس وتنسيق الالوان.',
          ),
        );
    });
  }

  /// Scrolls the list to the bottom after the current frame is rendered.
  /// The extra 140 px offset ensures the last bubble clears the input bar.
  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 140,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(' Outfit Advisor'),
        actions: [
          IconButton(
            // Disabled when the conversation has only the welcome message.
            onPressed: _messages.length <= 1 ? null : _newChat,
            tooltip: 'محادثة جديدة',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          children: [
            // Scope reminder banner shown at the top of every session.
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.xs,
              ),
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: AppColors.border),
              ),
              child: const Text(
                'صفحة محادثة مخصصة للملابس فقط. اسأل عن التنسيق، الالوان، الملابس المناسبة للمناسبة، والخامات.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                // One extra item slot is reserved for the typing indicator.
                itemCount: _messages.length + (_sending ? 1 : 0),
                itemBuilder: (context, i) {
                  if (_sending && i == _messages.length) {
                    return const _TypingBubble();
                  }
                  return _Bubble(message: _messages[i]);
                },
              ),
            ),
            // Horizontal quick-reply chip row.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.xs,
              ),
              child: SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _examples.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.xs),
                  itemBuilder: (context, i) {
                    final text = _examples[i];
                    return ActionChip(
                      onPressed: _sending ? null : () => _send(text),
                      label: Text(text, style: const TextStyle(fontSize: 12)),
                      backgroundColor: AppColors.surface,
                      side: const BorderSide(color: AppColors.border),
                    );
                  },
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.md,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(color: AppColors.border),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      textDirection: TextDirection.rtl,
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'اكتب سؤالك عن الموضة...',
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FloatingActionButton.small(
                    heroTag: 'chat_send_fab_v2',
                    onPressed: _sending ? null : _send,
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    child: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Role { user, assistant }

class _Message {
  const _Message({required this.role, required this.text});

  final _Role role;
  final String text;
}

/// Chat bubble for a single message.
/// User bubbles are right-aligned with the primary colour;
/// assistant bubbles are left-aligned on a white background.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final _Message message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == _Role.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: isUser ? AppColors.primary : Colors.white,
            // The "tail" of the bubble is created by giving one bottom corner
            // a tighter radius depending on which side the bubble sits.
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(AppRadius.lg),
              topRight: const Radius.circular(AppRadius.lg),
              bottomLeft: Radius.circular(isUser ? AppRadius.lg : 6),
              bottomRight: Radius.circular(isUser ? 6 : AppRadius.lg),
            ),
            border: isUser
                ? null
                : Border.all(color: AppColors.border.withValues(alpha: 0.9)),
          ),
          child: SelectableText(
            message.text,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: isUser ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder bubble displayed while the assistant response is in flight.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// System prompt that scopes the assistant strictly to fashion and clothing.
/// Sent as a separate `systemInstruction` field, not as part of `contents`,
/// so it never appears in the visible conversation history.
const String _systemPrompt = '''
انت مساعد مختص في الملابس والموضة فقط.

نطاقك المسموح:
- تنسيق الملابس
- اقتراح الالوان المتناسقة
- اقتراح اطلالات حسب المناسبة والطقس
- خامات الملابس والطبقات والاكسسوارات

اذا كان السؤال خارج الموضة، ارفض بلطف في سطر واحد واطلب سؤال متعلق بالملابس.

قواعد الرد:
- الرد يكون بالعربية فقط
- الرد يكون عملي وقصير
- استخدم نقاط واضحة عند الحاجة
- الرد نص فقط بدون صور او روابط صور
- لا تدعي تجربة ملابس حقيقية او قدرات غير متاحة
''';
