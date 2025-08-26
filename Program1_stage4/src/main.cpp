#include <iostream>
#include <string>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <algorithm>
#include <cctype>
#include <vector>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>

std::string buffer;
std::mutex mtx;
std::condition_variable cv;
bool finished = false;

int serverSocket = -1;
int clientSocket = -1;

// === Проверка строки ===
bool isValidDigits(const std::string &s) {
    return !s.empty() && s.size() <= 64 &&
           std::all_of(s.begin(), s.end(), ::isdigit);
}

// === Преобразование строки ===
std::string transformInput(const std::string &input) {
    std::string sorted = input;
    std::sort(sorted.begin(), sorted.end(), std::greater<char>());
    std::string transformed;
    for (char c : sorted) {
        if ((c - '0') % 2 == 0)
            transformed += "KV";
        else
            transformed.push_back(c);
    }
    return transformed;
}

// === Обработка строки ===
int processString(const std::string &data) {
    int sum = 0;
    for (char c : data) {
        if (isdigit(c)) sum += c - '0';
    }
    return sum;
}

// === Поток: ввод из консоли ===
void producerConsole() {
    while (true) {
        std::string input;
        std::cout << "Введите строку (или 'exit' для выхода): ";
        std::cin >> input;

        if (input == "exit") {
            finished = true;
            cv.notify_all();
            break;
        }

        if (!isValidDigits(input)) {
            std::cout << "[input] Ошибка: вводите только цифры, не больше 64 символов.\n";
            continue;
        }

        std::string transformed = transformInput(input);

        {
            std::lock_guard<std::mutex> lock(mtx);
            buffer = transformed;
        }
        cv.notify_one();
    }
}

// === Поток: обработка буфера ===
void consumer() {
    while (true) {
        std::unique_lock<std::mutex> lock(mtx);
        cv.wait(lock, [] { return !buffer.empty() || finished; });

        if (finished && buffer.empty()) break;

        std::string data = buffer;
        buffer.clear();
        lock.unlock();

        std::cout << "Получено из буфера: " << data << std::endl;

        int sum = processString(data);
        std::cout << "Сумма цифр: " << sum << std::endl;

        if (clientSocket != -1) {
            std::string message = "SUM:" + std::to_string(sum) + "\n";
            ssize_t sent = send(clientSocket, message.c_str(), message.size(), 0);
            if (sent == -1) {
                std::cerr << "[server] Ошибка отправки, соединение разорвано.\n";
                close(clientSocket);
                clientSocket = -1;
            }
        }
    }
}

// === Поток: приём данных от клиента ===
void clientReceiver() {
    char buf[1024];
    while (!finished) {
        if (clientSocket == -1) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        ssize_t received = recv(clientSocket, buf, sizeof(buf) - 1, 0);
        if (received > 0) {
            buf[received] = '\0';
            std::string input(buf);
            input.erase(std::remove(input.begin(), input.end(), '\n'), input.end());
            std::cout << "[client] Ввод: " << input << std::endl;

            if (!isValidDigits(input)) {
                std::string error = "ERROR: only digits, max 64 chars\n";
                send(clientSocket, error.c_str(), error.size(), 0);
                continue;
            }

            std::string transformed = transformInput(input);
            int sum = processString(transformed);

            std::cout << "[client] Преобразовано: " << transformed 
                      << " | сумма = " << sum << std::endl;

            std::string message = "SUM:" + std::to_string(sum) + "\n";
            send(clientSocket, message.c_str(), message.size(), 0);
        }
        else if (received == 0) {
            std::cout << "[server] Клиент отключился.\n";
            close(clientSocket);
            clientSocket = -1;
        }
    }
}

// === Поток: ожидание клиента ===
void acceptorThread() {
    while (true) {
        int newSocket = accept(serverSocket, nullptr, nullptr);
        if (newSocket == -1) {
            perror("accept");
            continue;
        }
        std::cout << "[server] Клиент подключен!\n";

        if (clientSocket != -1) {
            close(clientSocket);
        }
        clientSocket = newSocket;
    }
}

int main() {
    // сервер
    serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (serverSocket == -1) {
        perror("socket");
        return 1;
    }

    int opt = 1;
    setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in serverAddr{};
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(3000);
    serverAddr.sin_addr.s_addr = INADDR_ANY;

    if (bind(serverSocket, (sockaddr*)&serverAddr, sizeof(serverAddr)) == -1) {
        perror("bind");
        return 1;
    }

    if (listen(serverSocket, 1) == -1) {
        perror("listen");
        return 1;
    }

    std::cout << "[server] Ожидание подключения на порту 3000...\n";

    std::thread t1(producerConsole);
    std::thread t2(consumer);
    std::thread t3(acceptorThread);
    std::thread t4(clientReceiver);

    t1.join();
    t2.join();

    close(serverSocket);
    if (clientSocket != -1) close(clientSocket);

    return 0;
}
