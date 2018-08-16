class wrong_case {
public:
    wrong_case() = default;
    wrong_case(const wrong_case& other) = delete;
    wrong_case& operator=(const wrong_case& other) = delete;
    ~wrong_case();
};
