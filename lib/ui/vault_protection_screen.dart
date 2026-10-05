import 'package:flutter/material.dart';

import '../storage/vault_protection.dart';
import 'app_theme.dart';
import 'widgets/brand_mark.dart';

typedef PasswordVaultCallback = Future<void> Function(String password);

class const VaultProtectionScreen({
  super.key,
  required final bool setup,
  required final bool systemVaultEnabled,
  required final PasswordVaultCallback onPassword,
  final Future<void> Function()? onSystem,
}) extends StatefulWidget {
  @override
  State<VaultProtectionScreen> createState() => _VaultProtectionScreenState();
}

class _VaultProtectionScreenState extends State<VaultProtectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  late VaultProtectionMode _mode;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mode = widget.systemVaultEnabled
        ? VaultProtectionMode.system
        : VaultProtectionMode.password;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (widget.setup && _mode == VaultProtectionMode.system) {
      final callback = widget.onSystem;
      if (callback == null) return;
      await _run(callback);
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    await _run(() => widget.onPassword(_passwordController.text));
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = widget.setup
            ? 'The encrypted vault could not be created. Please try again.'
            : 'The password is incorrect or the vault cannot be opened.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const BrandMark(),
                      const SizedBox(height: 28),
                      Text(
                        widget.setup ? 'Protect your vault' : 'Unlock vault',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.setup
                            ? 'Choose how Sygnature protects the encryption '
                                  'keys stored on this device.'
                            : 'Enter the password used to encrypt this vault.',
                      ),
                      if (widget.setup) ...[
                        const SizedBox(height: 22),
                        _ProtectionOption(
                          key: const Key('system-vault-option'),
                          title: 'System vault',
                          description: widget.systemVaultEnabled
                              ? 'Unlock automatically using this device\'s '
                                    'secure storage.'
                              : 'Unavailable on macOS builds distributed '
                                    'without Keychain access.',
                          icon: Icons.security_rounded,
                          mode: VaultProtectionMode.system,
                          selected: _mode == VaultProtectionMode.system,
                          enabled: widget.systemVaultEnabled && !_busy,
                          onSelected: () => setState(
                            () => _mode = VaultProtectionMode.system,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _ProtectionOption(
                          key: const Key('password-vault-option'),
                          title: 'Password',
                          description:
                              'Enter the password whenever Sygnature starts. '
                              'It is never stored on this device.',
                          icon: Icons.password_rounded,
                          mode: VaultProtectionMode.password,
                          selected: _mode == VaultProtectionMode.password,
                          enabled: !_busy,
                          onSelected: () => setState(
                            () => _mode = VaultProtectionMode.password,
                          ),
                        ),
                      ],
                      if (!widget.setup ||
                          _mode == VaultProtectionMode.password) ...[
                        const SizedBox(height: 22),
                        TextFormField(
                          key: const Key('vault-password'),
                          controller: _passwordController,
                          enabled: !_busy,
                          obscureText: _obscurePassword,
                          autofillHints: widget.setup
                              ? const [AutofillHints.newPassword]
                              : const [AutofillHints.password],
                          textInputAction: widget.setup
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted: widget.setup
                              ? null
                              : (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: 'Vault password',
                            suffixIcon: IconButton(
                              tooltip: _obscurePassword
                                  ? 'Show password'
                                  : 'Hide password',
                              onPressed: _busy
                                  ? null
                                  : () => setState(
                                      () =>
                                          _obscurePassword = !_obscurePassword,
                                    ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Enter a vault password.';
                            }
                            if (widget.setup && value.length < 12) {
                              return 'Use at least 12 characters.';
                            }
                            return null;
                          },
                        ),
                        if (widget.setup) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const Key('vault-password-confirmation'),
                            controller: _confirmationController,
                            enabled: !_busy,
                            obscureText: _obscurePassword,
                            autofillHints: const [AutofillHints.newPassword],
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                            ),
                            validator: (value) =>
                                value == _passwordController.text
                                ? null
                                : 'Passwords do not match.',
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'This password cannot be recovered. Your recovery '
                            'phrase can restore wallet funds, but not local app '
                            'data.',
                            style: TextStyle(
                              color: AppColors.warningDark,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          key: const Key('vault-protection-error'),
                          style: const TextStyle(color: AppColors.danger),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('vault-protection-submit'),
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  widget.setup ? 'Continue' : 'Unlock vault',
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class const _ProtectionOption({
  super.key,
  required final String title,
  required final String description,
  required final IconData icon,
  required final VaultProtectionMode mode,
  required final bool selected,
  required final bool enabled,
  required final VoidCallback onSelected,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: enabled ? onSelected : null,
    borderRadius: BorderRadius.circular(8),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: selected && enabled ? AppColors.successSurface : null,
        border: Border.all(
          color: selected && enabled ? AppColors.green : AppColors.line,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: enabled ? AppColors.greenDark : AppColors.inkMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: enabled ? AppColors.ink : AppColors.inkMuted,
                  ),
                ),
                const SizedBox(height: 3),
                Text(description),
              ],
            ),
          ),
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: enabled ? AppColors.greenDark : AppColors.inkMuted,
          ),
        ],
      ),
    ),
  );
}
