// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of flutter_blue_plus;

class BluetoothCharacteristic
{
    final Guid uuid;
    final DeviceIdentifier deviceId;
    final Guid serviceUuid;
    final Guid? secondaryServiceUuid;
    final CharacteristicProperties properties;
    final List<BluetoothDescriptor> descriptors;

    final _Mutex _readWriteMutex = _Mutex();

    /// This variable is updated *live* if:
    ///   - you call value.listen() 
    ///   - or, you call onValueChangedStream.listen()
    /// And updated *once* if:
    ///   - you call read()
    List<int> lastValue;

    /// this stream is pushed to:
    ///   - the first time it is listened to (see: BehaviorSubject)
    ///   - after 'read' is called
    final _BehaviorSubject<List<int>> _readValueController;

    BluetoothCharacteristic.fromProto(BmBluetoothCharacteristic p)
        : uuid = Guid(p.uuid),
        deviceId = DeviceIdentifier(p.remoteId),
        serviceUuid = Guid(p.serviceUuid),
        secondaryServiceUuid = p.secondaryServiceUuid != null ? Guid(p.secondaryServiceUuid!) : null,
        descriptors = p.descriptors.map((d) => BluetoothDescriptor.fromProto(d)).toList(),
        properties = CharacteristicProperties.fromProto(p.properties),
        lastValue = p.value,
        _readValueController = _BehaviorSubject<List<int>>(p.value);

    /// This stream is pushed to:
    ///   - the first time it is listened to
    ///   - after 'read' is called
    ///   - if setNotifyValue(true) and the operating system receives a change
    Stream<List<int>> get value => _mergeStreams([
        _readValueController.stream, 
        onValueChangedStream
    ]);

    /// This stream is pushed to when:
    ///   - setNotifyValue(true) and the operating system receives a change
    Stream<List<int>> get onValueChangedStream => FlutterBluePlus.instance._methodStream
        .where((m) => m.method == "OnCharacteristicChanged")
        .map((m) => m.arguments)
        .map((buffer) => BmOnCharacteristicChanged.fromJson(buffer))
        .where((p) => p.remoteId == deviceId.toString())
        .map((p) => BluetoothCharacteristic.fromProto(p.characteristic))
        .where((c) => c.uuid == uuid)
        .map((c) {
            _updateDescriptors(c.descriptors); // Update descriptors
            lastValue = c.lastValue; // Update cache of lastValue
            return c.lastValue;
    });

    bool get isNotifying
    {
        try {
            var cccd = descriptors.singleWhere((d) => d.uuid == BluetoothDescriptor.cccd);
            return ((cccd.lastValue[0] & 0x01) > 0 || (cccd.lastValue[0] & 0x02) > 0);
        } catch (e) {
            return false;
        }
    }

    void _updateDescriptors(List<BluetoothDescriptor> newDescriptors)
    {
        for (var d in descriptors) {
            for (var newD in newDescriptors) {
                if (d.uuid == newD.uuid) {
                    d._value.add(newD.lastValue);
                }
            }
        }
    }

    /// Retrieves the value of the characteristic
    Future<List<int>> read() async
    {
        List<int> responseValue = [];

        // Only allow a single read or write operation
        // at a time, to prevent race conditions.
        await _readWriteMutex.synchronized(() async {

            var request = BmReadCharacteristicRequest(
              remoteId: deviceId.toString(), 
              characteristicUuid: uuid.toString(),
              serviceUuid: serviceUuid.toString(), 
              secondaryServiceUuid: null,
            );

            FlutterBluePlus.instance._log(LogLevel.info,
                'remoteId: ${deviceId.toString()}' 
                'characteristicUuid: ${uuid.toString()}'
                'serviceUuid: ${serviceUuid.toString()}');

            var responseStream = FlutterBluePlus.instance._methodStream
                .where((m) => m.method == "ReadCharacteristicResponse")
                .map((m) => m.arguments)
                .map((buffer) => BmReadCharacteristicResponse.fromJson(buffer))
                .where((p) =>
                    (p.remoteId == request.remoteId) &&
                    (p.characteristic.uuid == request.characteristicUuid) &&
                    (p.characteristic.serviceUuid == request.serviceUuid))
                .map((p) => p.characteristic.value);

            // Start listening now, before invokeMethod, to ensure we don't miss the response
            Future<List<int>> futureResponse = responseStream.first;

            await FlutterBluePlus.instance._channel
                .invokeMethod('readCharacteristic', request.toJson());

            responseValue = await futureResponse;

            // push to stream
            _readValueController.add(responseValue);

            // cache latest value
            lastValue = responseValue;
        }).catchError((e, stacktrace) {
            throw Exception("$e $stacktrace");
        });

        return responseValue;
    }

    /// Writes the value of a characteristic.
    /// [CharacteristicWriteType.withoutResponse]: the write is not
    /// guaranteed and will return immediately with success.
    /// [CharacteristicWriteType.withResponse]: the method will return after the
    /// write operation has either passed or failed.
    Future<void> write(List<int> value, {bool withoutResponse = false}) async
    {
        // Only allow a single read or write operation
        // at a time, to prevent race conditions.
        await _readWriteMutex.synchronized(() async {

            final writeType = withoutResponse
                ? BmWriteType.withoutResponse
                : BmWriteType.withResponse;

            var request = BmWriteCharacteristicRequest(
                remoteId: deviceId.toString(),
                characteristicUuid: uuid.toString(),
                serviceUuid: serviceUuid.toString(),
                secondaryServiceUuid: null,
                writeType: writeType,
                value: value,
            );

            if (writeType == BmWriteType.withResponse) {

                var responseStream = FlutterBluePlus.instance._methodStream
                    .where((m) => m.method == "WriteCharacteristicResponse")
                    .map((m) => m.arguments)
                    .map((buffer) => BmWriteCharacteristicResponse.fromJson(buffer))
                    .where((p) =>
                        (p.request.remoteId == request.remoteId) &&
                        (p.request.characteristicUuid == request.characteristicUuid) &&
                        (p.request.serviceUuid == request.serviceUuid));

                // Start listening now, before invokeMethod, to ensure we don't miss the response
                Future<BmWriteCharacteristicResponse> futureResponse = responseStream.first;

                await FlutterBluePlus.instance._channel
                    .invokeMethod('writeCharacteristic', request.toJson());

                // wait for response, so that we can check for success
                BmWriteCharacteristicResponse response = await futureResponse;
                if (!response.success) {
                    throw Exception('Failed to write the characteristic');
                }

                return Future.value();

            } else {
                // invoke without waiting for reply
                return FlutterBluePlus.instance._channel
                    .invokeMethod('writeCharacteristic', request.toJson());
            }
        }).catchError((e, stacktrace) {
            throw Exception("$e $stacktrace");
        });
    }

    /// Sets notifications or indications for the value of a specified characteristic
    Future<bool> setNotifyValue(bool notify) async
    {
        var request = BmSetNotificationRequest(
            remoteId: deviceId.toString(),
            serviceUuid: serviceUuid.toString(),
            characteristicUuid: uuid.toString(),
            secondaryServiceUuid: null,
            enable: notify,
        );

        Stream<BmSetNotificationResponse> responseStream = FlutterBluePlus.instance._methodStream
            .where((m) => m.method == "SetNotificationResponse")
            .map((m) => m.arguments)
            .map((buffer) => BmSetNotificationResponse.fromJson(buffer))
            .where((p) =>
                (p.remoteId == request.remoteId) &&
                (p.characteristic.uuid == request.characteristicUuid) &&
                (p.characteristic.serviceUuid == request.serviceUuid));

        // Start listening now, before invokeMethod, to ensure we don't miss the response
        Future<BmSetNotificationResponse> futureResponse = responseStream.first;

        await FlutterBluePlus.instance._channel
            .invokeMethod('setNotification', request.toJson());

        // wait for response, so that we can check for success
        BmSetNotificationResponse response = await futureResponse;
        if (!response.success) {
              throw Exception('setNotifyValue failed');
        }

        BluetoothCharacteristic c = BluetoothCharacteristic.fromProto(response.characteristic);
        _updateDescriptors(c.descriptors);
        return c.isNotifying == notify;
    }

    @override
    String toString()
    {
        return 'BluetoothCharacteristic{'
        'uuid: $uuid, '
        'deviceId: $deviceId, '
        'serviceUuid: $serviceUuid, '
        'secondaryServiceUuid: $secondaryServiceUuid, '
        'properties: $properties, '
        'descriptors: $descriptors, '
        'value: $lastValue'
        '}';
    }
}

class CharacteristicProperties
{
    final bool broadcast;
    final bool read;
    final bool writeWithoutResponse;
    final bool write;
    final bool notify;
    final bool indicate;
    final bool authenticatedSignedWrites;
    final bool extendedProperties;
    final bool notifyEncryptionRequired;
    final bool indicateEncryptionRequired;

    const CharacteristicProperties({
        this.broadcast = false,
        this.read = false,
        this.writeWithoutResponse = false,
        this.write = false,
        this.notify = false,
        this.indicate = false,
        this.authenticatedSignedWrites = false,
        this.extendedProperties = false,
        this.notifyEncryptionRequired = false,
        this.indicateEncryptionRequired = false
    });

    CharacteristicProperties.fromProto(BmCharacteristicProperties p)
        : broadcast = p.broadcast,
        read = p.read,
        writeWithoutResponse = p.writeWithoutResponse,
        write = p.write,
        notify = p.notify,
        indicate = p.indicate,
        authenticatedSignedWrites = p.authenticatedSignedWrites,
        extendedProperties = p.extendedProperties,
        notifyEncryptionRequired = p.notifyEncryptionRequired,
        indicateEncryptionRequired = p.indicateEncryptionRequired;

    @override
    String toString()
    {
        return 'CharacteristicProperties{'
        'broadcast: $broadcast, '
        'read: $read, '
        'writeWithoutResponse: $writeWithoutResponse, '
        'write: $write, '
        'notify: $notify, '
        'indicate: $indicate, '
        'authenticatedSignedWrites: $authenticatedSignedWrites, '
        'extendedProperties: $extendedProperties, '
        'notifyEncryptionRequired: $notifyEncryptionRequired, '
        'indicateEncryptionRequired: $indicateEncryptionRequired'
        '}';
    }
}