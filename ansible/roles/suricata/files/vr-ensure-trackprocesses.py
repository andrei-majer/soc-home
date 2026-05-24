#!/usr/bin/env python3
import json

f = '/opt/velociraptor/config/client_monitoring.json.db'
with open(f) as fh:
    d = json.load(fh)

arts = d['artifacts']['artifacts']
if 'Windows.Events.TrackProcesses' not in arts:
    arts.append('Windows.Events.TrackProcesses')
    d['artifacts'].pop('compiledCollectorArgs', None)
    with open(f, 'w') as fh:
        json.dump(d, fh)
    print('changed')
else:
    print('ok')
