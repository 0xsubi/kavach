import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  Future<List<DeviceRecord>>? _future;
  String? _approvingDeviceId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _future = ref.read(vaultControllerProvider.notifier).listDevices();
    });
  }

  Future<void> _approve(DeviceRecord device) async {
    setState(() {
      _approvingDeviceId = device.deviceId;
      _error = null;
    });
    try {
      await ref.read(vaultControllerProvider.notifier).approveDevice(device);
      _load();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _approvingDeviceId = null);
    }
  }

  Future<void> _invite() async {
    final notifier = ref.read(vaultControllerProvider.notifier);
    try {
      final target = await notifier.storageTarget();
      final invite = await notifier.createDeviceInvite();
      if (!mounted || target == null) return;
      final inviteLink = DeviceInviteUri(
        baseUrl: target.baseUrl,
        vaultId: target.vaultId,
        inviteToken: invite.inviteToken,
      ).encode();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: KavachColors.surface,
          insetPadding: const EdgeInsets.all(12),
          title: const Text('invite a device', style: TextStyle(color: KavachColors.textPrimary, fontSize: 15)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'point the new device\'s camera at this code — it opens Kavach '
                  'with the details filled in. expires in 15 minutes, works once.',
                  style: TextStyle(color: KavachColors.textSecondary, fontSize: 11),
                ),
                const SizedBox(height: 12),
                Center(
                  child: KavachQrCode(
                    data: inviteLink,
                    size: 168,
                    semanticLabel: 'device invite QR code',
                  ),
                ),
                const SizedBox(height: 12),
                const Row(
                  children: [
                    Expanded(child: Divider(color: KavachColors.border)),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        'or type them in',
                        style: TextStyle(color: KavachColors.textSecondary, fontSize: 10),
                      ),
                    ),
                    Expanded(child: Divider(color: KavachColors.border)),
                  ],
                ),
                const SizedBox(height: 10),
                _copyableField('server url', target.baseUrl),
                const SizedBox(height: 8),
                _copyableField('vault id', target.vaultId),
                const SizedBox(height: 8),
                _copyableField('invite token', invite.inviteToken),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: inviteLink)),
              child: const Text('copy link'),
            ),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('done')),
          ],
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Widget _copyableField(String label, String value) {
    return InkWell(
      onTap: () => Clipboard.setData(ClipboardData(text: value)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: KavachColors.textSecondary, fontSize: 10)),
          Row(
            children: [
              Expanded(
                child: SelectableText(value, style: const TextStyle(color: KavachColors.textPrimary, fontSize: 12)),
              ),
              const Icon(Icons.copy, size: 14, color: KavachColors.textSecondary),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        title: const Text('devices', style: TextStyle(color: KavachColors.textPrimary, fontSize: 16)),
        actions: [
          IconButton(icon: const Icon(Icons.person_add_alt_outlined), tooltip: 'invite a device', onPressed: _invite),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh', onPressed: _load),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<DeviceRecord>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(color: KavachColors.accent));
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    snapshot.error.toString(),
                    style: const TextStyle(color: KavachColors.danger, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final devices = snapshot.data ?? const [];
            if (devices.isEmpty) {
              return const Center(
                child: Text(
                  'no devices found on the remote vault yet.\nsync at least once first.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KavachColors.textSecondary, fontSize: 12),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: devices.length + (_error != null ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                if (_error != null && index == 0) {
                  return Text(_error!, style: const TextStyle(color: KavachColors.danger, fontSize: 12));
                }
                final device = devices[index - (_error != null ? 1 : 0)];
                return _DeviceTile(
                  device: device,
                  busy: _approvingDeviceId == device.deviceId,
                  onApprove: () => _approve(device),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.busy, required this.onApprove});

  final DeviceRecord device;
  final bool busy;
  final VoidCallback onApprove;

  @override
  Widget build(BuildContext context) {
    final pending = device.status == DeviceStatus.pending;
    return KavachCard(
      child: Row(
        children: [
          KavachIconCircle(
            icon: pending ? Icons.hourglass_top_outlined : Icons.check_circle_outline,
            size: 36,
            iconSize: 16,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.platform,
                  style: const TextStyle(color: KavachColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 13),
                ),
                Text(
                  '${device.deviceId} · ${device.status.name}',
                  style: const TextStyle(color: KavachColors.textSecondary, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (pending) KavachButton(label: busy ? '…' : 'approve', onTap: busy ? null : onApprove),
        ],
      ),
    );
  }
}
