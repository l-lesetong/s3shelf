import json
import pathlib
import re
import subprocess
import sys
import os

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])

def completions(line):
    completer = root / 'aws_completer'
    result = subprocess.check_output([completer], env={**os.environ, 'COMP_LINE': line, 'COMP_POINT': str(len(line))}, text=True)
    return {item for item in result.splitlines() if not item.startswith('-')}

def kebab(name):
    name = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1-\2', name)
    return re.sub(r'([a-z0-9])([A-Z])', r'\1-\2', name).lower()

catalog = []
for service in ('s3api', 's3control', 's3files', 's3outposts', 's3tables', 's3vectors'):
    model_dir = sorted((root / 'awscli/botocore/data' / ('s3' if service == 's3api' else service)).iterdir())[-1]
    model = json.loads((model_dir / 'service-2.json').read_text())
    cli_commands = completions(f'aws {service} ')
    operations = {kebab(name): operation for name, operation in model['operations'].items()}
    waiters = {}
    if 'wait' in cli_commands:
        waiters = json.loads((model_dir / 'waiters-2.json').read_text())['waiters']
        cli_commands.remove('wait')
        for name, waiter in waiters.items():
            operation = {**model['operations'][waiter['operation']], 'waiter': True}
            operations[f'wait {kebab(name)}'] = operation
        cli_commands |= {f'wait {name}' for name in completions(f'aws {service} wait ')}
    assert cli_commands == operations.keys(), (service, cli_commands - operations.keys(), operations.keys() - cli_commands)
    for name, operation in sorted(operations.items()):
        shapes = model['shapes']
        input_shape = shapes.get(operation.get('input', {}).get('shape'), {})
        output_shape = shapes.get(operation.get('output', {}).get('shape'), {})
        members = input_shape.get('members', {})
        streaming_in = [key for key, member in members.items() if member.get('streaming') or shapes[member['shape']].get('streaming')]
        streaming_out = name == 'select-object-content' or any(
            member.get('streaming') or shapes[member['shape']].get('streaming')
            or shapes[member['shape']].get('eventstream') for member in output_shape.get('members', {}).values()
        )
        def template(member, depth=0):
            shape = shapes[member['shape']]
            kind = shape['type']
            if kind == 'structure':
                return {key: template(shape['members'][key], depth+1) for key in shape.get('required', [])} if depth < 12 else {}
            if kind == 'list':
                return [template(shape['member'], depth+1)] if depth < 12 else []
            return {'string': '', 'timestamp': '2026-01-01T00:00:00Z', 'blob': '', 'boolean': False, 'integer': 0, 'long': 0, 'double': 0.0, 'float': 0.0, 'map': {}}.get(kind, '')
        required = input_shape.get('required', [])
        doc = operation.get('documentation', '')
        summary = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', doc.split('</p>', 1)[0])).strip()
        catalog.append(dict(service=service, name=name, summary=summary[:290], required=required,
                            fields=list(members), template={key:template(member) for key, member in members.items() if key not in streaming_in},
                            fileInput=streaming_in[0] if streaming_in else None, fileOutput=streaming_out,
                            mutates=operation['http']['method'] not in ('GET','HEAD') and not name.startswith(('get-', 'list-', 'query-', 'describe-', 'wait '))))
output.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + '\n')
print(f'{len(catalog)} AWS operations')
