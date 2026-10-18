module issue_23;

enum customUDA;
struct customStructUDA {
	string s;
}

@customUDA @customStructUDA("custom uda") @("test name") @("this is ignored")
unittest {}