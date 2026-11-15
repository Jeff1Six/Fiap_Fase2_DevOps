"""Aplica instrumentacao OTel nos 3 servicos Flask do ToggleMaster.
Execute na raiz do repositorio: python instrumentar_python.py
Revisar git diff antes de commit/deploy.
"""
from pathlib import Path

ROOT = Path.cwd()
SERVICES = ('flag-service', 'targeting-service', 'analytics-service')
DEPS = [
    'opentelemetry-sdk',
    'opentelemetry-exporter-otlp-proto-http',
    'opentelemetry-instrumentation-flask',
    'opentelemetry-instrumentation-requests',
    'opentelemetry-instrumentation-botocore',
]
HELPER = '''"""Inicializacao de tracing OpenTelemetry do ToggleMaster.

As credenciais do New Relic pertencem somente ao Collector.
As aplicacoes exportam para o endereco OTLP interno do Kubernetes.
"""
import os
import atexit
import logging

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.propagate import set_global_textmap

DEFAULT_OTLP = (
    "http://togglemaster-otel-opentelemetry-collector."
    "monitoring.svc.cluster.local:4318/v1/traces"
)
_initialized = False


def instrument_app(app, service_name):
    global _initialized
    if _initialized:
        return
    _initialized = True

    endpoint = os.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", DEFAULT_OTLP)
    provider = TracerProvider(resource=Resource.create({"service.name": service_name}))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint)))
    trace.set_tracer_provider(provider)
    set_global_textmap(TraceContextTextMapPropagator())
    atexit.register(provider.shutdown)

    FlaskInstrumentor().instrument_app(app, excluded_urls="/health")
    RequestsInstrumentor().instrument()
    if service_name == "analytics-service":
        # O worker publica/consome mensagens SQS usando boto3/botocore.
        from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
        BotocoreInstrumentor().instrument()
    logging.getLogger(__name__).info("OpenTelemetry ativado: %s", service_name)
'''


def patch_service(service):
    folder = ROOT / service
    app = folder / 'app.py'
    requirements = folder / 'requirements.txt'
    if not app.is_file() or not requirements.is_file():
        raise FileNotFoundError(f'Arquivos app.py/requirements.txt ausentes em {folder}')

    text = app.read_text(encoding='utf-8')
    anchor = 'app = Flask(__name__)'
    if text.count(anchor) != 1:
        raise ValueError(f'Esperado um unico app = Flask(__name__) em {app}')
    if 'from otel_setup import instrument_app' not in text:
        text = text.replace(anchor, anchor + f'\n\nfrom otel_setup import instrument_app\ninstrument_app(app, "{service}")', 1)
        app.write_text(text, encoding='utf-8', newline='\n')

    helper = folder / 'otel_setup.py'
    if not helper.exists():
        helper.write_text(HELPER, encoding='utf-8', newline='\n')

    old = requirements.read_text(encoding='utf-8')
    installed = {line.split('==')[0].split('>=')[0].split('~=')[0].strip().lower()
                 for line in old.splitlines()}
    missing = [dep for dep in DEPS if dep.lower() not in installed]
    if missing:
        requirements.write_text(old.rstrip() + '\n' + '\n'.join(missing) + '\n', encoding='utf-8', newline='\n')

    if service == 'analytics-service':
        docker = folder / 'Dockerfile'
        d = docker.read_text(encoding='utf-8')
        # Analytics copia apenas app.py, ao contrario dos outros servicos.
        if 'COPY otel_setup.py .' not in d:
            if d.count('COPY app.py .') != 1:
                raise ValueError('Nao achei COPY app.py . no Dockerfile de analytics')
            docker.write_text(d.replace('COPY app.py .', 'COPY app.py .\nCOPY otel_setup.py .', 1), encoding='utf-8', newline='\n')
    print(f'Instrumentacao Python preparada: {service}')


if __name__ == '__main__':
    if not (ROOT / '.git').is_dir():
        raise SystemExit('Execute este script na raiz do repositorio que possui .git')
    for name in SERVICES:
        patch_service(name)
    print('Concluido. Revise git diff e execute testes antes de fazer deploy.')
