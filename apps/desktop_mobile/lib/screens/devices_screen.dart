import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

/// Lists every device registered against this vault's repo and lets the
/// user approve any that are pending (plan §5 "new device onboarding").
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        title: const Text('Devices', style: TextStyle(color: KavachColors.textPrimary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
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
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    snapshot.error.toString(),
                    style: const TextStyle(color: KavachColors.danger),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final devices = snapshot.data ?? const [];
            if (devices.isEmpty) {
              return const Center(
                child: Text(
                  'No devices found on the remote vault yet.\nSync at least once first.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KavachColors.textSecondary),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: devices.length + (_error != null ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                if (_error != null && index == 0) {
                  return Text(_error!, style: const TextStyle(color: KavachColors.danger));
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
            size: 44,
            iconSize: 20,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.platform,
                  style: const TextStyle(
                    color: KavachColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${device.deviceId} · ${device.status.name}',
                  style: const TextStyle(color: KavachColors.textSecondary, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (pending)
            KavachButton(
              label: busy ? '…' : 'Approve',
              onTap: busy ? null : onApprove,
            ),
        ],
      ),
    );
  }
}
