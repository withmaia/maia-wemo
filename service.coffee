UpnpControlPoint = require('node-upnp-controlpoint').UpnpControlPoint
wemo = require('node-upnp-controlpoint/lib/wemo')
util = require 'util'
somata = require 'somata/src'
_ = require 'underscore'
redis = require('redis').createClient()
{log} = somata.helpers

slugify = (s) ->
    s.toLowerCase().replace(/\s+/g, ' ')

# Device name reference {id: name, ...}
device_names = {}
device_slugs = {}
redis.hgetall 'wemo:device_names', (err, _device_names) ->
    device_names = _device_names if _device_names
    device_slugs = _.invert _.object _.map(device_names, (v, k) -> [k, slugify v])
    console.log '[device slugs]', util.inspect device_slugs

# Device references {id: device, ...}
devices = {}

getDevice = (id) ->
    console.log '[getDevice] -> id ' + id
    if _.isObject id
        id = _.invert(device_names)[id.name]
    else
        id = device_slugs[id] || id

    devices[id]

client = new somata.Client

wemo_service = new somata.Service 'maia:wemo',

    switches: (cb) ->
        switches = _.filter devices, (_device) ->
            _device.type == 'switch'
        switch_descs = _.map switches, (_switch) ->
            o = _.pick(_switch, 'id', 'state')
            o.name = device_names[o.id] || 'New Switch'
            o.slug = slugify o.name
            return o
        cb null, switch_descs

    sensors: (cb) ->
        sensors = _.filter devices, (_device) ->
            _device.type == 'sensor'
        sensor_descs = _.map sensors, (_sensor) ->
            o = _.pick(_sensor, 'id', 'state')
            o.name = device_names[o.id] || 'New Sensor'
            o.slug = slugify o.name
            return o
        cb null, sensor_descs

    getState: (id, cb) ->
        device = getDevice(id)
        cb null, device.state

    setState: (id, new_state, cb) ->
        device = getDevice(id)
        log "[set] #{ device.id } ==> #{ new_state }"
        device.control.setBinaryState new_state
        client.remote 'tenna:wemo', 'setState', id, {on: new_state}, cb
        cb null, new_state

    update: (id, data, cb) ->
        redis.hset 'wemo:device_names', id, data.name, (err, set) ->
            device_names[id] = data.name
            cb null, 'ok'

interpretState = (value) ->
    if typeof value == 'number'
        return true if (value == 1)
        return false if (value == 0)
    else if typeof value == 'string'
        return interpretState Number value.split('|')[0]
    else
        log '[interpretState] Could not interpret: ' + value
        return null

makeSwitch = (device) ->
    _switch =
        id: device.uuid
        type: 'switch'
        control: new wemo.WemoControllee(device)

    devices[_switch.id] = _switch

    # Subscribe to UPNP state change events
    _switch.control.on "BinaryState", (value) ->
        _state = interpretState value
        return if !_state?

        slug = slugify device_names[_switch.id] || _switch.id
        log "[onBinaryState] <#{ slug }> #{ value } => #{ _state }"

        if _state != _switch.state
            # Publish change events
            wemo_service.publish "change:switches/#{ slug }/state", _state
            wemo_service.publish "changeState", {wemo_id: _switch.id, state: _state}
            _switch.state = _state

makeSensor = (device) ->
    _sensor =
        id: device.uuid
        type: 'sensor'
        control: new wemo.WemoSensor(device)

    devices[_sensor.id] = _sensor

    # Subscribe to UPNP state change events
    _sensor.control.on "BinaryState", (value) ->
        _state = interpretState value
        return if !_state?

        slug = slugify device_names[_sensor.id] || _switch.id
        log "[onBinaryState] <#{ slug }> #{ value } => #{ _state }"

        if _state != _sensor.state
            # Publish change events
            wemo_service.publish "change:sensors/#{ slug }/state", _state
            _sensor.state = _state

switch_types = ['urn:Belkin:device:insight:1', 'urn:Belkin:device:controllee:1']
sensor_types = ['urn:Belkin:device:sensor:1']

handleDevice = (device) ->
    if device.deviceType in switch_types
        makeSwitch device
        log.i '[handleDevice] Created switch: ' + device.deviceType
    else if device.deviceType in sensor_types
        makeSensor device
        log.i '[handleDevice] Created sensor: ' + device.deviceType
    else
        log '[handleDevice] Unrecognized device: ' + device.deviceType

cp = new UpnpControlPoint()
cp.on "device", handleDevice
cp.search()

