"""Inicializacao de tracing OpenTelemetry do ToggleMaster.

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
