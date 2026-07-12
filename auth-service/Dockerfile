# Etapa 1: build da aplicação
FROM golang:1.21-alpine AS builder

WORKDIR /app

# Copia primeiro os arquivos de dependência para aproveitar cache
COPY go.mod go.sum ./

RUN go mod download

# Copia o restante do projeto
COPY . .

# Gera binário Linux estático
RUN CGO_ENABLED=0 GOOS=linux go build -o auth-service .

# Etapa 2: imagem final, menor
FROM alpine:3.20

WORKDIR /app

# Cria usuário sem privilégios
RUN adduser -D appuser

# Copia somente o binário gerado
COPY --from=builder /app/auth-service .

USER appuser

EXPOSE 8001

CMD ["./auth-service"]