FROM node:20-alpine AS build

WORKDIR /app
COPY examples/rekt-crud/web/package*.json ./
RUN npm ci
COPY examples/rekt-crud/web/index.html examples/rekt-crud/web/tsconfig.json ./
COPY examples/rekt-crud/web/src ./src
ENV VITE_STACK_LABEL=PRK
ENV VITE_STACK_DETAIL="Prologue + React + KoutenDB"
RUN npm run build

FROM nginx:1.27-alpine
COPY examples/rekt-crud/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
