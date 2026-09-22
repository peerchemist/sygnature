import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/wallet_controller.dart';
import '../models/mnemonic_seed.dart';
import 'app_theme.dart';
import 'widgets/brand_mark.dart';

enum _SetupStep { mnemonic, derivation }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.controller});

  final WalletController controller;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  _SetupStep _step = _SetupStep.mnemonic;
  MnemonicLanguage? _language = MnemonicLanguage.byId('english');
  int _wordCount = 12;
  int? _loadedWordCount;
  String? _wordlistError;
  bool _loadingWordlist = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _selectLanguage(_language);
    });
  }

  Future<void> _selectLanguage(MnemonicLanguage? language) async {
    if (language == null) return;
    setState(() {
      _language = language;
      _loadedWordCount = null;
      _wordlistError = null;
      _loadingWordlist = true;
    });
    try {
      final source = await rootBundle.loadString(language.assetPath);
      final count = const LineSplitter()
          .convert(source)
          .where((word) => word.trim().isNotEmpty)
          .length;
      if (!mounted || _language?.id != language.id) return;
      setState(() {
        _loadedWordCount = count;
        _loadingWordlist = false;
        if (count != 2048) {
          _wordlistError = 'Expected 2,048 words, found $count.';
        }
      });
    } catch (_) {
      if (!mounted || _language?.id != language.id) return;
      setState(() {
        _wordlistError = 'Unable to load the selected wordlist.';
        _loadingWordlist = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final stepNumber = _step.index + 1;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const BrandMark(),
                          const Spacer(),
                          Text(
                            'SETUP $stepNumber OF 2',
                            style: const TextStyle(
                              color: AppColors.inkMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: stepNumber / 2,
                        minHeight: 3,
                        backgroundColor: AppColors.line,
                      ),
                      const SizedBox(height: 26),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 120),
                        child: switch (_step) {
                          _SetupStep.mnemonic => _MnemonicStep(
                            key: const ValueKey('mnemonic'),
                            language: _language,
                            wordCount: _wordCount,
                            loadedWordCount: _loadedWordCount,
                            loadingWordlist: _loadingWordlist,
                            wordlistError: _wordlistError,
                            onLanguageChanged: _selectLanguage,
                            onWordCountChanged: (value) =>
                                setState(() => _wordCount = value),
                            onContinue: _loadedWordCount == 2048
                                ? () => setState(
                                    () => _step = _SetupStep.derivation,
                                  )
                                : null,
                          ),
                          _SetupStep.derivation => _DerivationStep(
                            key: const ValueKey('derivation'),
                            language: _language!,
                            wordCount: _wordCount,
                            busy: widget.controller.busy,
                            onBack: () =>
                                setState(() => _step = _SetupStep.mnemonic),
                            onOpenWallet: () =>
                                widget.controller.createWalletShell(
                                  languageId: _language!.id,
                                  mnemonicWordCount: _wordCount,
                                ),
                          ),
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MnemonicStep extends StatelessWidget {
  const _MnemonicStep({
    super.key,
    required this.language,
    required this.wordCount,
    required this.loadedWordCount,
    required this.loadingWordlist,
    required this.wordlistError,
    required this.onLanguageChanged,
    required this.onWordCountChanged,
    required this.onContinue,
  });

  final MnemonicLanguage? language;
  final int wordCount;
  final int? loadedWordCount;
  final bool loadingWordlist;
  final String? wordlistError;
  final ValueChanged<MnemonicLanguage?> onLanguageChanged;
  final ValueChanged<int> onWordCountChanged;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mnemonic', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        const Text(
          'Configure the recovery phrase source.',
          style: TextStyle(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 540;
            final languageField = DropdownButtonFormField<MnemonicLanguage>(
              key: const Key('mnemonic-language-field'),
              initialValue: language,
              decoration: const InputDecoration(labelText: 'Wordlist language'),
              isExpanded: true,
              items: MnemonicLanguage.supported
                  .map(
                    (item) =>
                        DropdownMenuItem(value: item, child: Text(item.label)),
                  )
                  .toList(growable: false),
              onChanged: onLanguageChanged,
            );
            final wordCountField = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Phrase length',
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
                ),
                const SizedBox(height: 5),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 12, label: Text('12 words')),
                    ButtonSegment(value: 24, label: Text('24 words')),
                  ],
                  selected: {wordCount},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      onWordCountChanged(selection.first),
                ),
              ],
            );
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  languageField,
                  const SizedBox(height: 16),
                  wordCountField,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: languageField),
                const SizedBox(width: 16),
                wordCountField,
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _StatusRow(icon: _statusIcon, label: _statusLabel, color: _statusColor),
        const SizedBox(height: 8),
        const _StatusRow(
          icon: Icons.pending_outlined,
          label: 'Recovery words: pending coinlib integration',
          color: AppColors.inkMuted,
        ),
        const SizedBox(height: 12),
        const Text(
          'No mnemonic is generated, accepted, or stored in this build.',
          style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: onContinue,
            child: const Text('Review derivation'),
          ),
        ),
      ],
    );
  }

  IconData get _statusIcon {
    if (language == null) return Icons.radio_button_unchecked;
    if (loadingWordlist) return Icons.sync;
    if (wordlistError != null) return Icons.error_outline;
    return Icons.check_circle_outline;
  }

  String get _statusLabel {
    if (language == null) return 'Wordlist: not selected';
    if (loadingWordlist) return 'Wordlist: loading';
    if (wordlistError != null) return wordlistError!;
    return 'Wordlist: ${language!.label}, ${loadedWordCount ?? 0} words';
  }

  Color get _statusColor {
    if (wordlistError != null) return Colors.red;
    if (loadedWordCount == 2048) return AppColors.greenDark;
    return AppColors.inkMuted;
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(label, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _DerivationStep extends StatelessWidget {
  const _DerivationStep({
    super.key,
    required this.language,
    required this.wordCount,
    required this.busy,
    required this.onBack,
    required this.onOpenWallet,
  });

  final MnemonicLanguage language;
  final int wordCount;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onOpenWallet;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Taproot account',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text(
          'Review the planned BIP-86 configuration.',
          style: TextStyle(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              _SetupRow(label: 'Wordlist', value: language.label),
              const Divider(height: 20),
              _SetupRow(label: 'Phrase', value: '$wordCount words'),
              const Divider(height: 20),
              const _SetupRow(label: 'Type', value: 'Taproot BIP-86'),
              const Divider(height: 20),
              const _SetupRow(
                label: 'Path',
                value: "m/86'/6'/0'/0/0",
                monospace: true,
              ),
              const Divider(height: 20),
              const _SetupRow(
                label: 'Seed and address',
                value: 'Pending coinlib',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'This creates only the local account structure. No cryptographic '
          'material is produced.',
          style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            OutlinedButton(onPressed: onBack, child: const Text('Back')),
            const Spacer(),
            FilledButton(
              onPressed: busy ? null : onOpenWallet,
              child: const Text('Open wallet shell'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: AppColors.inkMuted, fontSize: 13),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }
}
