from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="env-keycloaked backend")


@app.middleware("http")
async def apply_forwarded_prefix(request: Request, call_next):
    forwarded_prefix = request.headers.get("x-forwarded-prefix")
    if forwarded_prefix:
        request.scope["root_path"] = forwarded_prefix.rstrip("/")
    return await call_next(request)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/hello")
def hello() -> dict[str, str]:
    return {"message": "Hello from FastAPI"}
