# Etapa 1: build da aplicaÃ§Ã£o
FROM golang:1.26-alpine AS builder

WORKDIR /app

# Copia primeiro os arquivos de dependÃªncia para aproveitar caches
COPY go.mod go.sum ./

RUN go mod download

# Copia o restante do projeto
COPY . .

# Gera binÃ¡rio Linux estÃ¡tico
RUN CGO_ENABLED=0 GOOS=linux go build -o auth-service .

# Etapa 2: imagem final, menor
FROM alpine:3.20

WORKDIR /app

# Cria usuÃ¡rio sem privilÃ©gios
RUN adduser -D appuser

# Copia somente o binÃ¡rio gerado
COPY --from=builder /app/auth-service .

USER appuser

EXPOSE 8001

CMD ["./auth-service"]
