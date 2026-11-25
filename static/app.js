const chat = document.getElementById("chat");
const form = document.getElementById("chat-form");
const input = document.getElementById("message");
const sendButton = document.getElementById("send-button");
const statusText = document.getElementById("status");

// Sovelluksen URL-etuliite, esimerkiksi /viikko5/
const BASE_PATH = window.location.pathname.endsWith("/")
    ? window.location.pathname
    : `${window.location.pathname}/`;

function createSessionId() {
    const values = new Uint8Array(16);
    crypto.getRandomValues(values);
    return Array.from(values, value => value.toString(16).padStart(2, "0")).join("");
}

let sessionId = localStorage.getItem("chat_session_id");

if (!sessionId) {
    sessionId = createSessionId();
    localStorage.setItem("chat_session_id", sessionId);
}

function addMessage(role, content) {
    const element = document.createElement("div");
    element.className = `message ${role}`;
    element.textContent = content;
    chat.appendChild(element);
    chat.scrollTop = chat.scrollHeight;
    return element;
}

async function loadHistory() {
    try {
        const response = await fetch(
            `${BASE_PATH}api/history/${encodeURIComponent(sessionId)}`
        );

        if (!response.ok) {
            throw new Error("Keskusteluhistorian lataaminen epäonnistui.");
        }

        const data = await response.json();

        if (data.messages.length > 0) {
            chat.replaceChildren();

            data.messages.forEach(message => {
                addMessage(message.role, message.content);
            });
        }
    } catch (error) {
        statusText.textContent = error.message;
    }
}

form.addEventListener("submit", async event => {
    event.preventDefault();

    const message = input.value.trim();

    if (!message) {
        return;
    }

    addMessage("user", message);
    input.value = "";
    sendButton.disabled = true;
    statusText.textContent = "Tekoäly vastaa...";

    const assistantElement = addMessage("assistant", "");

    try {
        const response = await fetch(`${BASE_PATH}api/chat`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                session_id: sessionId,
                message: message
            })
        });

        if (!response.ok) {
            throw new Error("Viestin lähettäminen epäonnistui.");
        }

        if (!response.body) {
            throw new Error("Palvelin ei palauttanut vastausvirtaa.");
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
            const { value, done } = await reader.read();

            if (done) {
                break;
            }

            buffer += decoder.decode(value, { stream: true });

            const lines = buffer.split("\n");
            buffer = lines.pop();

            for (const line of lines) {
                if (!line.trim()) {
                    continue;
                }

                const data = JSON.parse(line);

                if (data.token) {
                    assistantElement.textContent += data.token;
                    chat.scrollTop = chat.scrollHeight;
                }

                if (data.error) {
                    throw new Error(data.error);
                }
            }
        }

        buffer += decoder.decode();

        if (buffer.trim()) {
            const data = JSON.parse(buffer);

            if (data.token) {
                assistantElement.textContent += data.token;
            }

            if (data.error) {
                throw new Error(data.error);
            }
        }

        if (!assistantElement.textContent) {
            assistantElement.textContent = "Tekoäly ei palauttanut vastausta.";
        }

        statusText.textContent = "Valmis.";

    } catch (error) {
        assistantElement.textContent = "Virhe: " + error.message;
        statusText.textContent = "Viestin käsittely epäonnistui.";
    } finally {
        sendButton.disabled = false;
        input.focus();
    }
});

loadHistory();
