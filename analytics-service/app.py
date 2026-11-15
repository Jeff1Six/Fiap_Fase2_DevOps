import os
import sys
import threading
import json
import uuid
import time
import logging

import boto3
from botocore.exceptions import NoCredentialsError, ClientError
from dotenv import load_dotenv
from flask import Flask, jsonify

# Configura o logging
logging.basicConfig(
    level=logging.INFO,
)
log = logging.getLogger(__name__)

# Carrega .env para desenvolvimento local
load_dotenv()

# --- Inicialização do Flask ---
app = Flask(__name__)

from otel_setup import instrument_app
instrument_app(app, "analytics-service")

# --- Configuração ---
AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")

SQS_ENDPOINT = os.getenv("AWS_SQS_ENDPOINT")
DYNAMODB_ENDPOINT = os.getenv("AWS_DYNAMODB_ENDPOINT")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.critical(
        "Erro: AWS_REGION, AWS_SQS_URL e AWS_DYNAMODB_TABLE "
        "devem ser definidos."
    )
    sys.exit(1)

# --- Clientes Boto3 ---
try:
    session = boto3.Session(region_name=AWS_REGION)

    sqs_client = session.client(
        "sqs",
        endpoint_url=SQS_ENDPOINT if SQS_ENDPOINT else None,
    )

    dynamodb_client = session.client(
        "dynamodb",
        endpoint_url=(
            DYNAMODB_ENDPOINT
            if DYNAMODB_ENDPOINT
            else None
        ),
    )

    log.info(
        "Clientes Boto3 inicializados na região %s",
        AWS_REGION,
    )

except NoCredentialsError:
    log.critical(
        "Credenciais da AWS não encontradas. "
        "Verifique seu ambiente."
    )
    sys.exit(1)

except Exception as e:
    log.critical(
        "Erro ao inicializar o Boto3: %s",
        e,
    )
    sys.exit(1)


# --- SQS Worker ---

def process_message(message):
    """Processa uma única mensagem SQS e a insere no DynamoDB."""
    try:
        log.info(
            "Processando mensagem ID: %s",
            message["MessageId"],
        )

        body = json.loads(message["Body"])

        event_id = str(uuid.uuid4())

        item = {
            "event_id": {
                "S": event_id,
            },
            "user_id": {
                "S": body["user_id"],
            },
            "flag_name": {
                "S": body["flag_name"],
            },
            "result": {
                "BOOL": body["result"],
            },
            "timestamp": {
                "S": body["timestamp"],
            },
        }

        dynamodb_client.put_item(
            TableName=DYNAMODB_TABLE_NAME,
            Item=item,
        )

        log.info(
            "Evento %s (Flag: %s) salvo no DynamoDB.",
            event_id,
            body["flag_name"],
        )

        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=message["ReceiptHandle"],
        )

    except json.JSONDecodeError:
        log.error(
            "Erro ao decodificar JSON da mensagem ID: %s",
            message["MessageId"],
        )

    except ClientError as e:
        log.error(
            "Erro do Boto3 (DynamoDB ou SQS) ao processar %s: %s",
            message["MessageId"],
            e,
        )

    except Exception as e:
        log.error(
            "Erro inesperado ao processar %s: %s",
            message["MessageId"],
            e,
        )


def sqs_worker_loop():
    """Loop principal do worker que ouve a fila SQS."""
    log.info("Iniciando o worker SQS...")

    while True:
        try:
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
            )

            messages = response.get(
                "Messages",
                [],
            )

            if not messages:
                continue

            log.info(
                "Recebidas %s mensagens.",
                len(messages),
            )

            for message in messages:
                process_message(message)

        except ClientError as e:
            log.error(
                "Erro do Boto3 no loop principal do SQS: %s",
                e,
            )
            time.sleep(10)

        except Exception as e:
            log.error(
                "Erro inesperado no loop principal do SQS: %s",
                e,
            )
            time.sleep(10)


@app.route("/health")
def health():
    return jsonify(
        {
            "status": "ok",
        }
    )


# --- Inicialização ---

def start_worker():
    """Inicia o worker SQS em uma thread separada."""
    worker_thread = threading.Thread(
        target=sqs_worker_loop,
        daemon=True,
    )
    worker_thread.start()


# Inicia o worker SQS em background
start_worker()


if __name__ == "__main__":
    port = int(
        os.getenv(
            "PORT",
            8005,
        )
    )

    app.run(
        host="0.0.0.0",  # nosec B104
        port=port,
        debug=False,
    )
