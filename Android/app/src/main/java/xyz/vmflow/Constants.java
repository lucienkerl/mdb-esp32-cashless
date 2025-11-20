package xyz.vmflow;

public final class Constants {

    private static Constants INSTANCE;
    private String SUPABASE_URL = "https://supabase.kerl.io";
    private String SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzYzNTkzMjAwLCJleHAiOjE5MjEzNTk2MDB9.KbMtGL7pbZ4xnHwHQRZfIGSJpI0SKtasQrSwehjA_Dk";

    private Constants() {
    }

    public static Constants getInstance() {
        if(INSTANCE == null) {
            INSTANCE = new Constants();
        }

        return INSTANCE;
    }

    // getters and setters

    public String getSUPABASE_URL() {
        return SUPABASE_URL;
    }

    public String getSUPABASE_KEY() {
        return SUPABASE_KEY;
    }
}
