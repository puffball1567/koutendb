FROM node:20-alpine AS build

WORKDIR /app
COPY examples/web/rekt-crud/web/package*.json ./
RUN npm ci
COPY examples/web/rekt-crud/web/index.html examples/web/rekt-crud/web/tsconfig.json ./
COPY examples/web/rekt-crud/web/src ./src
ENV VITE_STACK_LABEL=PRK
ENV VITE_STACK_DETAIL="Prologue + React + KoutenDB"
RUN npm run build

FROM nginx:1.27-alpine
COPY examples/web/rekt-crud/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
