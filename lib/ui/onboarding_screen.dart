import 'package:flutter/material.dart';

import '../controllers/wallet_controller.dart';
import '../models/mnemonic_seed.dart';
import 'app_theme.dart';
import 'widgets/brand_mark.dart';

enum _SetupStep { mnemonic, backup }

enum _MnemonicSource { generate, import }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.controller, this.onCreated});

  final WalletController controller;
  final VoidCallback? onCreated;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  _SetupStep _step = _SetupStep.mnemonic;
  _MnemonicSource _source = _MnemonicSource.generate;
  final TextEditingController _importController = TextEditingController();
  MnemonicLanguage? _language = MnemonicLanguage.english;
  int _wordCount = 12;
  MnemonicSession? _mnemonic;
  bool _backupConfirmed = false;
  String? _mnemonicError;
  String? _importError;
  String? _creationError;

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  void _selectLanguage(MnemonicLanguage? language) {
    if (language == null) return;
    setState(() {
      _language = language;
      _mnemonic = null;
      _backupConfirmed = false;
      _mnemonicError = null;
      _importError = null;
    });
  }

  void _generateMnemonic() {
    final language = _language;
    if (language == null) return;
    try {
      final mnemonic = widget.controller.generateMnemonic(
        language: language,
        wordCount: _wordCount,
      );
      setState(() {
        _mnemonic = mnemonic;
        _backupConfirmed = false;
        _creationError = null;
        _step = _SetupStep.backup;
      });
    } catch (_) {
      setState(() => _mnemonicError = 'Unable to generate recovery words.');
    }
  }

  void _importMnemonic() {
    final language = _language;
    if (language == null) return;
    try {
      final result = widget.controller.validateMnemonic(
        mnemonic: _importController.text,
        language: language,
      );
      if (!result.isValid) {
        setState(() => _importError = result.error);
        return;
      }
      setState(() {
        _mnemonic = MnemonicSession(
          words: result.words,
          language: language,
          createdInApp: false,
        );
        _backupConfirmed = false;
        _creationError = null;
        _importError = null;
        _step = _SetupStep.backup;
      });
    } catch (_) {
      setState(() {
        _importError = 'Unable to validate the recovery phrase.';
      });
    }
  }

  Future<void> _createWallet() async {
    final mnemonic = _mnemonic;
    if (mnemonic == null || !_backupConfirmed) return;
    setState(() => _creationError = null);
    try {
      await widget.controller.createVault(mnemonic);
      widget.onCreated?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _creationError = 'Unable to create the wallet. Please try again.';
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
                            source: _source,
                            language: _language,
                            wordCount: _wordCount,
                            mnemonicError: _mnemonicError,
                            importController: _importController,
                            importError: _importError,
                            onSourceChanged: (selection) => setState(() {
                              _source = selection.first;
                              _mnemonic = null;
                              _backupConfirmed = false;
                              _creationError = null;
                              _importError = null;
                            }),
                            onLanguageChanged: _selectLanguage,
                            onWordCountChanged: (value) => setState(() {
                              _wordCount = value;
                              _mnemonic = null;
                            }),
                            onImportChanged: (_) => setState(() {
                              _importError = null;
                            }),
                            onContinue: _source == _MnemonicSource.generate
                                ? _generateMnemonic
                                : _importMnemonic,
                          ),
                          _SetupStep.backup => _BackupStep(
                            key: const ValueKey('backup'),
                            mnemonic: _mnemonic!,
                            busy: widget.controller.busy,
                            backupConfirmed: _backupConfirmed,
                            creationError: _creationError,
                            onBackupConfirmed: (value) => setState(
                              () => _backupConfirmed = value ?? false,
                            ),
                            onBack: () => setState(() {
                              _mnemonic = null;
                              _backupConfirmed = false;
                              _creationError = null;
                              _importError = null;
                              _step = _SetupStep.mnemonic;
                            }),
                            onCreateWallet: _createWallet,
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
    required this.source,
    required this.language,
    required this.wordCount,
    required this.mnemonicError,
    required this.importController,
    required this.importError,
    required this.onSourceChanged,
    required this.onLanguageChanged,
    required this.onWordCountChanged,
    required this.onImportChanged,
    required this.onContinue,
  });

  final _MnemonicSource source;
  final MnemonicLanguage? language;
  final int wordCount;
  final String? mnemonicError;
  final TextEditingController importController;
  final String? importError;
  final ValueChanged<Set<_MnemonicSource>> onSourceChanged;
  final ValueChanged<MnemonicLanguage?> onLanguageChanged;
  final ValueChanged<int> onWordCountChanged;
  final ValueChanged<String> onImportChanged;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mnemonic', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 6),
        const Text(
          'Choose how to set up the recovery phrase for personal wallets.',
          style: TextStyle(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 20),
        SegmentedButton<_MnemonicSource>(
          segments: const [
            ButtonSegment(
              value: _MnemonicSource.generate,
              label: Text('Create new'),
            ),
            ButtonSegment(
              value: _MnemonicSource.import,
              label: Text('Import existing'),
            ),
          ],
          selected: {source},
          showSelectedIcon: false,
          onSelectionChanged: onSourceChanged,
        ),
        const SizedBox(height: 16),
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
            final phraseInput = source == _MnemonicSource.generate
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Phrase length',
                        style: TextStyle(
                          color: AppColors.inkMuted,
                          fontSize: 12,
                        ),
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
                  )
                : TextField(
                    key: const Key('recovery-phrase-field'),
                    controller: importController,
                    minLines: 3,
                    maxLines: 5,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: InputDecoration(
                      labelText: 'Recovery phrase',
                      alignLabelWithHint: true,
                      errorText: importError,
                    ),
                    onChanged: onImportChanged,
                  );
            if (source == _MnemonicSource.import) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  languageField,
                  const SizedBox(height: 16),
                  phraseInput,
                ],
              );
            }
            final wordCountField = phraseInput;
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
        _StatusRow(
          icon: Icons.shield_outlined,
          label: source == _MnemonicSource.generate
              ? 'Recovery words: generated securely on this device'
              : 'Recovery phrase: validated locally on this device',
          color: AppColors.greenDark,
        ),
        const SizedBox(height: 12),
        Text(
          source == _MnemonicSource.generate
              ? 'Your phrase will be shown once. Keep it private and store it '
                    'offline.'
              : 'The phrase is never sent over the network. Select its '
                    'wordlist language before continuing.',
          style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.center,
          child: FilledButton(
            key: const Key('mnemonic-continue-button'),
            onPressed: onContinue,
            child: Text(
              source == _MnemonicSource.generate
                  ? 'Generate recovery phrase'
                  : 'Review import',
            ),
          ),
        ),
      ],
    );
  }

  IconData get _statusIcon {
    if (language == null) return Icons.radio_button_unchecked;
    if (mnemonicError != null) return Icons.error_outline;
    return Icons.check_circle_outline;
  }

  String get _statusLabel {
    if (language == null) return 'Wordlist: not selected';
    if (mnemonicError != null) return mnemonicError!;
    return 'Wordlist: ${language!.label}, 2048 words';
  }

  Color get _statusColor {
    if (mnemonicError != null) return Colors.red;
    return language == null ? AppColors.inkMuted : AppColors.greenDark;
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

class _BackupStep extends StatelessWidget {
  const _BackupStep({
    super.key,
    required this.mnemonic,
    required this.busy,
    required this.backupConfirmed,
    required this.creationError,
    required this.onBackupConfirmed,
    required this.onBack,
    required this.onCreateWallet,
  });

  final MnemonicSession mnemonic;
  final bool busy;
  final bool backupConfirmed;
  final String? creationError;
  final ValueChanged<bool?> onBackupConfirmed;
  final VoidCallback onBack;
  final Future<void> Function() onCreateWallet;

  @override
  Widget build(BuildContext context) {
    final generated = mnemonic.createdInApp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          generated ? 'Back up recovery phrase' : 'Review recovery phrase',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          generated
              ? 'Write these recovery words down in order. Anyone with this '
                    'phrase can spend your funds.'
              : 'Confirm this recovery phrase before storing it in the '
                    'encrypted local vault.',
          style: const TextStyle(color: AppColors.inkMuted),
        ),
        if (generated) ...[
          const SizedBox(height: 20),
          _RecoveryPhrase(words: mnemonic.words),
        ],
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              _SetupRow(label: 'Wordlist', value: mnemonic.language.label),
              const Divider(height: 20),
              _SetupRow(
                label: 'Phrase',
                value: '${mnemonic.words.length} words',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          value: backupConfirmed,
          onChanged: busy ? null : onBackupConfirmed,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(
            generated
                ? 'I wrote down these recovery words in order.'
                : 'I have a secure backup of this recovery phrase.',
          ),
          subtitle: const Text(
            'The mnemonic will be stored only in the encrypted local vault. '
            'Each wallet chooses its own network when added.',
          ),
        ),
        if (creationError != null) ...[
          const SizedBox(height: 8),
          Text(creationError!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            OutlinedButton(onPressed: onBack, child: const Text('Back')),
            const Spacer(),
            FilledButton(
              key: const Key('wallet-create-button'),
              onPressed: busy || !backupConfirmed ? null : onCreateWallet,
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save recovery phrase'),
            ),
          ],
        ),
      ],
    );
  }
}

class _RecoveryPhrase extends StatelessWidget {
  const _RecoveryPhrase({required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Recovery phrase with ${words.length} words',
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (index, word) in words.indexed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '${index + 1}. $word',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({required this.label, required this.value});

  final String label;
  final String value;

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
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
