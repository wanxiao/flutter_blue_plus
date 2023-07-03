// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of flutter_blue_plus;

class BluetoothDevice
{
    final DeviceIdentifier id;
    final String name;
    final BluetoothDeviceType type;

    final _BehaviorSubject<List<BluetoothService>> _services = _BehaviorSubject([]);

    final _BehaviorSubject<bool> _isDiscoveringServices = _BehaviorSubject(false);
    
    Stream<bool> get isDiscoveringServices => _isDiscoveringServices.stream;
  
    BluetoothDevice.fromProto(BmBluetoothDevice p)
        : id = DeviceIdentifier(p.remoteId),
        name = p.name ?? "",
        type = bmToBluetoothDeviceType(p.type);
  
    /// Use on Android when the MAC address is known.
    /// This constructor enables the Android to connect to a specific device
    /// as soon as it becomes available on the bluetooth "network".
    BluetoothDevice.fromId(String id, {String? name, BluetoothDeviceType? type})
        : id = DeviceIdentifier(id),
        name = name ?? "Unknown name",
        type = type ?? BluetoothDeviceType.unknown;
  
    /// Establishes a connection to the Bluetooth Device.
    Future<void> connect({
        Duration? timeout,
        bool autoConnect = true,
        bool shouldClearGattCache = true,
    }) async
    {
        if (Platform.isAndroid && shouldClearGattCache) {
            clearGattCache();
        }
  
        var request = BmConnectRequest(
            remoteId: id.toString(),
            androidAutoConnect: autoConnect,
        );
  
        var responseStream = state.where((s) => s == BluetoothDeviceState.connected);
  
        // Start listening now, before invokeMethod, to ensure we don't miss the response
        Future<BluetoothDeviceState> futureState = responseStream.first;
  
        await FlutterBluePlus.instance._channel
              .invokeMethod('connect', request.toJson());
  
        // wait for connection
        if (timeout != null) {
            await futureState.timeout(timeout, onTimeout: () {
                throw TimeoutException('Failed to connect in time.', timeout);
            });
        } else {
            await futureState;
        }
    }
  
    /// Send a pairing request to the device.
    /// Currently only implemented on Android.
    Future<void> pair() async
    {
        return FlutterBluePlus.instance._channel
            .invokeMethod('pair', id.toString());
    }
  
    /// Refresh Gatt Device Cache
    /// Emergency method to reload ble services & characteristics
    /// Currently only implemented on Android.
    Future<void> clearGattCache() async
    {
        if (Platform.isAndroid) {
            return FlutterBluePlus.instance._channel
                .invokeMethod('clearGattCache', id.toString());
        }
    }
  
    /// Cancels connection to the Bluetooth Device
    Future<void> disconnect() async
    {
        await FlutterBluePlus.instance._channel
            .invokeMethod('disconnect', id.toString());
    } 
  
    /// Discovers services offered by the remote device 
    /// as well as their characteristics and descriptors
    Future<List<BluetoothService>> discoverServices() async
    {
        final s = await state.first;
        if (s != BluetoothDeviceState.connected) {
            return Future.error(Exception('Cannot discoverServices while'
                'device is not connected. State == $s'));
        }
  
        // signal that we have started
        _isDiscoveringServices.add(true);
  
        var responseStream = FlutterBluePlus.instance._methodStream
            .where((m) => m.method == "DiscoverServicesResult")
            .map((m) => m.arguments)
            .map((buffer) => BmDiscoverServicesResult.fromJson(buffer))
            .where((p) => p.remoteId == id.toString())
            .map((p) => p.services)
            .map((s) => s.map((p) => BluetoothService.fromProto(p)).toList());
  
        // Start listening now, before invokeMethod, to ensure we don't miss the response
        Future<List<BluetoothService>> futureResponse = responseStream.first;
  
        await FlutterBluePlus.instance._channel
            .invokeMethod('discoverServices', id.toString());
  
        // wait for response
        List<BluetoothService> services = await futureResponse;
  
        _isDiscoveringServices.add(false);
        _services.add(services);
  
        return services;
    }
  
    /// Returns a list of Bluetooth GATT services offered by the remote device
    /// This function requires that discoverServices has been completed for this device
    Stream<List<BluetoothService>> get services async*
    {
        List<BluetoothService> initialServices = await FlutterBluePlus.instance._channel
            .invokeMethod('services', id.toString())
            .then((buffer) => BmDiscoverServicesResult.fromJson(buffer).services)
            .then((i) => i.map((s) => BluetoothService.fromProto(s)).toList());

        yield initialServices;
            
        yield* _services.stream;
    }
  
    /// The current connection state of the device
    Stream<BluetoothDeviceState> get state async*
    {
        BluetoothDeviceState initialState = await FlutterBluePlus.instance._channel
            .invokeMethod('deviceState', id.toString())
            .then((buffer) => BmConnectionStateResponse.fromJson(buffer))
            .then((p) => bmToBluetoothDeviceState(p.state));

        yield initialState;
  
        yield* FlutterBluePlus.instance._methodStream
            .where((m) => m.method == "DeviceState")
            .map((m) => m.arguments)
            .map((buffer) => BmConnectionStateResponse.fromJson(buffer))
            .where((p) => p.remoteId == id.toString())
            .map((p) => bmToBluetoothDeviceState(p.state));
    }
  
    /// The MTU size in bytes
    Stream<int> get mtu async*
    {
        int initialMtu = await FlutterBluePlus.instance._channel
            .invokeMethod('mtu', id.toString())
            .then((buffer) => BmMtuSizeResponse.fromJson(buffer))
            .then((p) => p.mtu);

        yield initialMtu;
  
        yield* FlutterBluePlus.instance._methodStream
            .where((m) => m.method == "MtuSize")
            .map((m) => m.arguments)
            .map((buffer) => BmMtuSizeResponse.fromJson(buffer))
            .where((p) => p.remoteId == id.toString())
            .map((p) => p.mtu);
    }
  
    /// Request to change the MTU Size
    /// Throws error if request did not complete successfully
    /// Request to change the MTU Size and returns the response back
    /// Throws error if request did not complete successfully
    Future<int> requestMtu(int desiredMtu) async
    {
        var request = BmMtuSizeRequest(
            remoteId: id.toString(),
            mtu: desiredMtu,
        );
  
        var responseStream = FlutterBluePlus.instance._methodStream
            .where((m) => m.method == "MtuSize")
            .map((m) => m.arguments)
            .map((buffer) => BmMtuSizeResponse.fromJson(buffer))
            .where((p) => p.remoteId == id.toString())
            .map((p) => p.mtu);
  
        // Start listening now, before invokeMethod, to ensure we don't miss the response
        Future<int> futureResponse = responseStream.first;
  
        await FlutterBluePlus.instance._channel
            .invokeMethod('requestMtu', request.toJson());
  
        var mtu = await futureResponse;
  
        return mtu;
    }
  
    /// Indicates whether the Bluetooth Device can 
    /// send a write without response
    Future<bool> get canSendWriteWithoutResponse =>
          Future.error(UnimplementedError());
  
    /// Read the RSSI for a connected remote device
    Future<int> readRssi() async
    {
        final remoteId = id.toString();
  
        var responseStream = FlutterBluePlus.instance._methodStream
            .where((m) => m.method == "ReadRssiResult")
            .map((m) => m.arguments)
            .map((buffer) => BmReadRssiResult.fromJson(buffer))
            .where((p) => (p.remoteId == remoteId))
            .map((result) => result.rssi);
  
        // Start listening now, before invokeMethod, to ensure we don't miss the response
        Future<int> futureRssi = responseStream.first;
  
        await FlutterBluePlus.instance._channel.invokeMethod('readRssi', remoteId);
  
        // wait for response
        int rssi = await futureRssi;
  
        return rssi;
    }
  
    /// Request a connection parameter update.
    ///
    /// This function will send a connection parameter update request to the
    /// remote device and is only available on Android.
    ///
    /// Request a specific connection priority. Must be one of
    /// ConnectionPriority.balanced, BluetoothGatt#ConnectionPriority.high or
    /// ConnectionPriority.lowPower.
    Future<void> requestConnectionPriority({required ConnectionPriority connectionPriorityRequest}) async 
    {
        int connectionPriority = 0;
  
        switch (connectionPriorityRequest) {
            case ConnectionPriority.balanced: connectionPriority = 0; break;
            case ConnectionPriority.high:     connectionPriority = 1; break;
            case ConnectionPriority.lowPower: connectionPriority = 2; break;
            default: break;
        }
  
        var request = BmConnectionPriorityRequest(
            remoteId: id.toString(),
            connectionPriority: connectionPriority,
        );
  
        await FlutterBluePlus.instance._channel.invokeMethod('requestConnectionPriority',request.toJson(),);
    }
  
    /// Set the preferred connection [txPhy], [rxPhy] and Phy [option] for this
    /// app. [txPhy] and [rxPhy] are int to be passed a masked value from the
    /// [PhyType] enum, eg `(PhyType.le1m.mask | PhyType.le2m.mask)`.
    ///
    /// Please note that this is just a recommendation, whether the PHY change
    /// will happen depends on other applications preferences, local and remote
    /// controller capabilities. Controller can override these settings. 
    Future<void> setPreferredPhy({
        required int txPhy,
        required int rxPhy,
        required PhyOption option,
    }) async
    {
        var request = BmPreferredPhy(
            remoteId: id.toString(),
            txPhy: txPhy,
            rxPhy: rxPhy,
            phyOptions: option.index,
        );
  
        await FlutterBluePlus.instance._channel.invokeMethod(
            'setPreferredPhy',
            request.toJson(),
        );
    }
  
    /// Only implemented on Android, for now
    Future<bool> removeBond() async
    {
        if (Platform.isAndroid) {
          return await FlutterBluePlus.instance._channel
                .invokeMethod('removeBond', id.toString())
                .then<bool>((value) => value);
        } else {
            return false;
        }
    }
  
    @override
    bool operator ==(Object other) =>
        identical(this, other) ||
        other is BluetoothDevice &&
        runtimeType == other.runtimeType &&
        id == other.id;
  
    @override
    int get hashCode => id.hashCode;
  
    @override
    String toString()
    {
        return 'BluetoothDevice{'
        'id: $id, '
        'name: $name, '
        'type: $type, '
        'isDiscoveringServices: ${_isDiscoveringServices.value}, '
        '_services: ${_services.value}'
        '}';
    }
}

enum BluetoothDeviceType
{ 
    unknown, 
    classic, 
    le, 
    dual 
}

BluetoothDeviceType bmToBluetoothDeviceType(BmBluetoothSpecEnum value) {
    switch(value) {
        case BmBluetoothSpecEnum.unknown: return BluetoothDeviceType.unknown;
        case BmBluetoothSpecEnum.classic: return BluetoothDeviceType.classic;
        case BmBluetoothSpecEnum.le:      return BluetoothDeviceType.le;
        case BmBluetoothSpecEnum.dual:    return BluetoothDeviceType.dual;
    }
}

enum BluetoothDeviceState
{
    disconnected, 
    connecting, 
    connected, 
    disconnecting
}

BluetoothDeviceState bmToBluetoothDeviceState(BmConnectionStateEnum value) {
    switch(value) {
        case BmConnectionStateEnum.disconnected:  return BluetoothDeviceState.disconnected;
        case BmConnectionStateEnum.connecting:    return BluetoothDeviceState.connecting;
        case BmConnectionStateEnum.connected:     return BluetoothDeviceState.connected;
        case BmConnectionStateEnum.disconnecting: return BluetoothDeviceState.disconnecting;
    }
}


enum ConnectionPriority
{
    balanced, 
    high, 
    lowPower
}

enum PhyType {
    le1m,
    le2m,
    leCoded
}

extension PhyTypeExt on PhyType {
  int get mask {
    switch (this) {
        case PhyType.le1m: return 1;
        case PhyType.le2m: return 2;
        case PhyType.leCoded: return 3;
        default: return 1;
    }
  }
}

enum PhyOption
{
    noPreferred,
    s2,
    s8
}
